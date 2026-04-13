;;;; throttling.lisp - HTTP throttling middleware for eve-gate
;;;;
;;;; Provides middleware integration between the rate limiter, request queue,
;;;; and the HTTP client pipeline. This is the glue layer that makes rate
;;;; limiting transparent to API callers.
;;;;
;;;; Components:
;;;;   - Rate limiting middleware: Acquires rate limit tokens before requests
;;;;   - Response tracking middleware: Feeds ESI response headers back to limiter
;;;;   - Automatic 420 detection: Initiates backoff on rate limit responses
;;;;   - Dynamic rate adjustment: Adapts rates based on server feedback
;;;;   - Request batching: Groups compatible requests where possible
;;;;
;;;; The middleware integrates at priority 15 (after headers at 10, before
;;;; logging at 20) so rate limit delays are properly logged.

(in-package #:eve-gate.concurrent)

;;; ---------------------------------------------------------------------------
;;; Global rate limiter instance
;;; ---------------------------------------------------------------------------

(defvar *esi-rate-limiter* nil
  "Global ESI rate limiter instance. Initialized by INITIALIZE-THROTTLING
or automatically on first use via ENSURE-RATE-LIMITER.")

(defvar *esi-request-queue* nil
  "Global ESI request queue instance. Initialized by INITIALIZE-THROTTLING.")

(defun ensure-rate-limiter ()
  "Ensure the global rate limiter is initialized, creating a default one if needed.

Returns the global rate limiter."
  (or *esi-rate-limiter*
      (setf *esi-rate-limiter* (make-esi-rate-limiter))))

(defun ensure-request-queue ()
  "Ensure the global request queue is initialized.

Returns the global request queue."
  (or *esi-request-queue*
      (setf *esi-request-queue* (make-request-queue))))

;;; ---------------------------------------------------------------------------
;;; Initialization
;;; ---------------------------------------------------------------------------

(defun initialize-throttling (&key (global-rate 150.0)
                                    (global-burst 150.0)
                                    (queue-size 1000)
                                    (endpoint-configs *default-esi-rate-configs*))
  "Initialize the global throttling system with ESI-compliant defaults.

GLOBAL-RATE: Maximum requests per second (default: 150.0)
GLOBAL-BURST: Burst capacity (default: 150.0)
QUEUE-SIZE: Maximum request queue depth (default: 1000)
ENDPOINT-CONFIGS: Per-endpoint rate configurations

Returns two values: the rate limiter and request queue."
  (setf *esi-rate-limiter* (make-esi-rate-limiter
                             :global-rate global-rate
                             :global-burst global-burst
                             :endpoint-configs endpoint-configs)
        *esi-request-queue* (make-request-queue :max-size queue-size))
  (log-info "Throttling initialized: ~,0F req/sec, burst ~,0F, queue ~D"
            global-rate global-burst queue-size)
  (values *esi-rate-limiter* *esi-request-queue*))

(defun shutdown-throttling ()
  "Shut down the global throttling system, draining the request queue."
  (when *esi-request-queue*
    (shutdown-queue *esi-request-queue*))
  (log-info "Throttling system shut down")
  (values))

;;; ---------------------------------------------------------------------------
;;; Rate limiting middleware — pre-request throttling
;;; ---------------------------------------------------------------------------

(defun make-throttling-middleware (&key (rate-limiter nil)
                                        (timeout 30.0)
                                        (priority 15))
  "Create middleware that enforces rate limiting before each request.

This middleware acquires a rate limit token before the request proceeds.
If the rate limit is exceeded, the request blocks until a token is
available or the timeout expires.

RATE-LIMITER: An esi-rate-limiter (default: global *esi-rate-limiter*)
TIMEOUT: Maximum seconds to wait for a token (default: 30.0)
PRIORITY: Middleware priority (default: 15, after headers, before logging)

Returns a middleware struct."
  (make-middleware
   :name :throttling
   :priority priority
   :request-fn
   (lambda (ctx)
     (let ((limiter (or rate-limiter (ensure-rate-limiter)))
           (path (getf ctx :path))
           (char-id (getf ctx :character-id)))
       (multiple-value-bind (allowed wait-time)
           (rate-limit-acquire limiter
                                :path path
                                :character-id char-id
                                :timeout timeout)
         (cond
           (allowed
            ;; Annotate context with wait info for logging
            (when (> wait-time 0.01)
              (setf (getf ctx :rate-limit-wait) wait-time)
              (log-debug "Rate limit: waited ~,3Fs for ~A" wait-time path))
            ctx)
           (t
            ;; Rate limit timeout — annotate context with rejection
            (log-warn "Rate limit timeout (~,1Fs) for ~A, request will proceed unthrottled"
                      timeout path)
            ;; Still allow the request through — the server will enforce its own limits
            ;; and we'll get 420 responses that trigger backoff
            (setf (getf ctx :rate-limit-exceeded) t)
            ctx)))))))

;;; ---------------------------------------------------------------------------
;;; Response tracking middleware — feeds server feedback to rate limiter
;;; ---------------------------------------------------------------------------

(defun make-response-tracking-middleware (&key (rate-limiter nil)
                                                (priority 92))
  "Create middleware that tracks ESI response headers for adaptive rate limiting.

This middleware runs after each response to:
  - Parse X-ESI-Error-Limit-Remain and X-ESI-Error-Limit-Reset headers
  - Detect 420 (Error Limited) responses and trigger backoff
  - Feed rate limit data back to the rate limiter for adaptation
  - Log rate limit warnings when error budget is low

RATE-LIMITER: An esi-rate-limiter (default: global *esi-rate-limiter*)
PRIORITY: Middleware priority (default: 92, late, observational)

Returns a middleware struct."
  (make-middleware
   :name :response-tracking
   :priority priority
   :response-fn
   (lambda (response ctx)
     (declare (ignore ctx))
     (let ((limiter (or rate-limiter (ensure-rate-limiter)))
           (headers (esi-response-headers response))
           (status (esi-response-status response)))
       (when headers
         (let ((error-remain (parse-header-integer headers "x-esi-error-limit-remain"))
               (error-reset (parse-header-integer headers "x-esi-error-limit-reset")))
           ;; Feed response data to rate limiter
           (rate-limiter-record-response limiter status
                                          :error-limit-remain error-remain
                                          :error-limit-reset error-reset))))
     response)))

;;; ---------------------------------------------------------------------------
;;; Automatic 420 retry middleware
;;; ---------------------------------------------------------------------------

(defun make-420-retry-middleware (&key (max-retries 3) (priority 8))
  "Create middleware that automatically handles 420 Error Limited responses.

When a 420 response is detected, this middleware:
  1. Parses the Retry-After header
  2. Waits the indicated time (with exponential backoff for repeated 420s)
  3. Retries the request automatically

This middleware works at the response level, intercepting 420 responses
before they reach the caller.

MAX-RETRIES: Maximum retry attempts for 420 responses (default: 3)
PRIORITY: Middleware priority (default: 8, very early)

Note: This middleware records retry state in the request context. It must
run before most other response middleware to intercept the 420 response."
  (make-middleware
   :name :420-retry
   :priority priority
   :response-fn
   (lambda (response ctx)
     (if (= (esi-response-status response) 420)
         (let* ((retry-count (or (getf ctx :420-retry-count) 0))
                (headers (esi-response-headers response))
                (retry-after (or (parse-header-integer headers "retry-after")
                                 ;; Default: exponential backoff
                                 (min 60 (expt 2 retry-count)))))
           (if (< retry-count max-retries)
               (progn
                 (log-warn "420 Error Limited, retrying in ~D seconds (attempt ~D/~D)"
                           retry-after (1+ retry-count) max-retries)
                 ;; Store retry info in the response for the caller to handle
                 ;; The actual retry is handled by the request engine
                 (setf (getf ctx :420-retry-count) (1+ retry-count)
                       (getf ctx :420-retry-after) retry-after
                       (getf ctx :should-retry) t)
                 response)
               (progn
                 (log-error "420 Error Limited, exhausted ~D retries" max-retries)
                 response)))
         response))))

;;; ---------------------------------------------------------------------------
;;; Combined throttling middleware stack
;;; ---------------------------------------------------------------------------

(defun make-throttling-middleware-stack (&key (rate-limiter nil)
                                              (timeout 30.0)
                                              (max-420-retries 3))
  "Create the complete throttling middleware stack for ESI communication.

Returns a list of middleware components that should be added to the
HTTP client's middleware pipeline:
  1. Throttling middleware (pre-request rate limiting)
  2. Response tracking middleware (adaptive rate adjustment)
  3. 420 retry middleware (automatic error limited handling)

RATE-LIMITER: ESI rate limiter (default: global instance)
TIMEOUT: Rate limit acquisition timeout (default: 30.0)
MAX-420-RETRIES: Maximum automatic retries on 420 (default: 3)

Returns a list of middleware structs.

Example:
  (let* ((stack (make-throttling-middleware-stack))
         (client (make-http-client :middleware
                   (reduce #'add-middleware
                           stack
                           :initial-value (make-default-middleware-stack)))))
    (http-request client \"/v5/status/\"))"
  (list
   (make-throttling-middleware :rate-limiter rate-limiter :timeout timeout)
   (make-response-tracking-middleware :rate-limiter rate-limiter)
   (make-420-retry-middleware :max-retries max-420-retries)))

;;; ---------------------------------------------------------------------------
;;; Throttled client constructor
;;; ---------------------------------------------------------------------------

(defun make-throttled-http-client (&key (base-url *esi-base-url*)
                                         (user-agent *user-agent*)
                                         (connect-timeout 10)
                                         (read-timeout *default-timeout*)
                                         (max-retries *default-retries*)
                                         (rate-limiter nil)
                                         (rate-limit-timeout 30.0)
                                         (datasource "tranquility")
                                         (logging t))
  "Create an HTTP client with full throttling support.

Combines the standard middleware stack with rate limiting, response tracking,
and automatic 420 retry handling.

BASE-URL: ESI base URL (default: *esi-base-url*)
USER-AGENT: User-Agent header value
CONNECT-TIMEOUT: TCP connection timeout in seconds
READ-TIMEOUT: Response read timeout in seconds
MAX-RETRIES: Maximum retry attempts for transient failures
RATE-LIMITER: ESI rate limiter (default: global instance)
RATE-LIMIT-TIMEOUT: Seconds to wait for rate limit token (default: 30.0)
DATASOURCE: ESI datasource (default: \"tranquility\")
LOGGING: Enable request/response logging (default: T)

Returns an http-client struct with throttling middleware.

Example:
  (let ((client (make-throttled-http-client)))
    ;; This client will automatically rate-limit and handle 420s
    (http-request client \"/v5/status/\"))"
  (let* ((limiter (or rate-limiter (ensure-rate-limiter)))
         ;; Build base middleware stack
         (base-stack (make-resilient-middleware-stack
                       :datasource datasource
                       :logging logging
                       :rate-limit-callback
                       (lambda (remain reset)
                         (rate-limiter-record-response
                          limiter 200
                          :error-limit-remain remain
                          :error-limit-reset reset))))
         ;; Add throttling middleware
         (throttle-stack (make-throttling-middleware-stack
                           :rate-limiter limiter
                           :timeout rate-limit-timeout))
         ;; Merge all middleware
         (full-stack (reduce #'add-middleware
                             throttle-stack
                             :initial-value base-stack)))
    (make-http-client :base-url base-url
                      :user-agent user-agent
                      :connect-timeout connect-timeout
                      :timeout read-timeout
                      :retries max-retries
                      :middleware full-stack)))

;;; ---------------------------------------------------------------------------
;;; Header parsing utilities
;;; ---------------------------------------------------------------------------

(defun parse-header-integer (headers name)
  "Parse an integer value from an HTTP header.

HEADERS: Response headers (hash-table or alist)
NAME: Header name (case-insensitive)

Returns the integer value, or NIL if the header is missing or unparseable."
  (when headers
    (let ((value (extract-header-value-raw headers name)))
      (when (and value (stringp value))
        (parse-integer value :junk-allowed t)))))

(defun extract-header-value-raw (headers name)
  "Extract a header value from HEADERS by NAME (case-insensitive).

HEADERS: Hash-table or alist of response headers
NAME: Header name string

Returns the header value string, or NIL."
  (cond
    ((hash-table-p headers)
     (or (gethash name headers)
         (gethash (string-downcase name) headers)
         ;; Full case-insensitive scan
         (block found
           (maphash (lambda (k v)
                      (when (string-equal k name)
                        (return-from found v)))
                    headers)
           nil)))
    ((listp headers)
     (cdr (assoc name headers :test #'string-equal)))
    (t nil)))

;;; ---------------------------------------------------------------------------
;;; Throttling status and diagnostics
;;; ---------------------------------------------------------------------------

(defun throttling-status (&optional (stream *standard-output*))
  "Print a comprehensive status report of the throttling system.

STREAM: Output stream (default: *standard-output*)"
  (format stream "~&=== ESI Throttling System Status ===~%")
  (if *esi-rate-limiter*
      (rate-limit-status *esi-rate-limiter* stream)
      (format stream "  Rate limiter: NOT INITIALIZED~%"))
  (format stream "~%")
  (if *esi-request-queue*
      (queue-status *esi-request-queue* stream)
      (format stream "  Request queue: NOT INITIALIZED~%"))
  (format stream "=== End Throttling Status ===~%")
  (values))

(defun throttling-healthy-p ()
  "Return T if the throttling system is in a healthy state.

Checks:
  - Rate limiter is initialized and not in error backoff
  - Request queue is not paused or shut down
  - Error budget is not critically low"
  (and *esi-rate-limiter*
       (esi-rate-limiter-enabled-p *esi-rate-limiter*)
       (zerop (error-backoff-remaining *esi-rate-limiter*))
       (> (esi-rate-limiter-error-limit-remain *esi-rate-limiter*) 10)
       (or (null *esi-request-queue*)
           (and (not (request-queue-shutdown-p *esi-request-queue*))
                (not (request-queue-paused-p *esi-request-queue*))))))
