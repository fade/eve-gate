;;;; esi-logger.lisp - ESI-specific structured logging for eve-gate
;;;;
;;;; Provides domain-specific logging functions for EVE Online ESI API
;;;; operations. These functions produce structured log entries with
;;;; consistent schemas for each event type, enabling efficient log
;;;; analysis and monitoring.
;;;;
;;;; Event categories:
;;;;   - HTTP request/response logging (with sanitization)
;;;;   - Rate limit event logging (420 responses, backoff events)
;;;;   - Authentication event logging (token refresh, scope validation)
;;;;   - Cache event logging (hits, misses, invalidations, ETag updates)
;;;;   - Error correlation and debugging context
;;;;
;;;; All functions in this module produce structured log entries via
;;;; LOG-EVENT from logging.lisp, ensuring consistent schema across
;;;; all ESI-related log output.
;;;;
;;;; Security: Authentication tokens and sensitive headers are sanitized
;;;; before logging. Only token presence/absence and expiry information
;;;; are recorded, never the actual token values.

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Sanitization utilities
;;; ---------------------------------------------------------------------------

(defun sanitize-headers-for-log (headers)
  "Remove or mask sensitive header values for safe logging.
Masks Authorization, Cookie, and Set-Cookie headers.

HEADERS: Alist or hash-table of HTTP headers

Returns an alist with sensitive values masked."
  (let ((sensitive-names '("authorization" "cookie" "set-cookie"
                           "x-token" "x-api-key")))
    (flet ((sensitive-p (name)
             (member (string-downcase name) sensitive-names :test #'string=))
           (mask-value (val)
             (if (and (stringp val) (> (length val) 8))
                 (concatenate 'string (subseq val 0 4) "****")
                 "****")))
      (cond
        ((null headers) nil)
        ((hash-table-p headers)
         (let ((result '()))
           (maphash (lambda (k v)
                      (push (cons k (if (sensitive-p k) (mask-value v) v))
                            result))
                    headers)
           result))
        ((listp headers)
         (mapcar (lambda (pair)
                   (cons (car pair)
                         (if (sensitive-p (car pair))
                             (mask-value (cdr pair))
                             (cdr pair))))
                 headers))
        (t nil)))))

(defun truncate-body-for-log (body &optional (max-length 500))
  "Truncate a response body for safe, bounded logging.

BODY: String or octets
MAX-LENGTH: Maximum characters to include (default: 500)

Returns a truncated string or NIL."
  (when body
    (let ((s (etypecase body
               (string body)
               (vector (format nil "<~D bytes>" (length body)))
               (t (princ-to-string body)))))
      (if (> (length s) max-length)
          (concatenate 'string (subseq s 0 max-length) "...[truncated]")
          s))))

;;; ---------------------------------------------------------------------------
;;; HTTP request/response logging
;;; ---------------------------------------------------------------------------

(defun log-esi-request (method path &key headers query-params
                                         character-id has-auth-p)
  "Log an outgoing ESI API request with structured fields.

METHOD: HTTP method keyword (:get, :post, etc.)
PATH: ESI endpoint path
HEADERS: Request headers (sanitized before logging)
QUERY-PARAMS: Query parameter alist
CHARACTER-ID: Associated character ID
HAS-AUTH-P: Whether request includes authentication

Example:
  (log-esi-request :get \"/v5/characters/12345/\"
                   :character-id 12345 :has-auth-p t)"
  (declare (ignore headers))
  (log-event :debug "ESI request"
             :source :http-client
             :method (string-downcase (symbol-name method))
             :path path
             :has-auth has-auth-p
             :character-id character-id
             :query-params (when query-params
                             (format nil "~{~A=~A~^&~}"
                                     (loop for (k . v) in query-params
                                           collect k collect v)))))

(defun log-esi-response (method path status &key latency-ms etag
                                                  cache-hit-p pages
                                                  error-limit-remain
                                                  content-length
                                                  character-id)
  "Log an ESI API response with structured performance and metadata fields.

METHOD: HTTP method keyword
PATH: ESI endpoint path
STATUS: HTTP status code
LATENCY-MS: Request latency in milliseconds
ETAG: Response ETag value
CACHE-HIT-P: Whether served from cache
PAGES: Total pages (for paginated responses)
ERROR-LIMIT-REMAIN: ESI error limit remaining
CONTENT-LENGTH: Response body size
CHARACTER-ID: Associated character ID

Example:
  (log-esi-response :get \"/v5/characters/12345/\" 200
                    :latency-ms 45.2 :cache-hit-p nil)"
  (let ((level (cond
                 ((< status 300) :debug)
                 ((< status 400) :debug)
                 ((= status 420) :warn)
                 ((< status 500) :warn)
                 (t :error))))
    (log-event level
               (format nil "ESI ~A ~A => ~D~@[ (~,1Fms)~]~@[ CACHED~]"
                       (string-downcase (symbol-name method))
                       path status latency-ms (when cache-hit-p t))
               :source :http-client
               :method (string-downcase (symbol-name method))
               :path path
               :status status
               :latency-ms (when latency-ms (round latency-ms 0.01))
               :cache-hit cache-hit-p
               :etag etag
               :pages pages
               :error-limit-remain error-limit-remain
               :content-length content-length
               :character-id character-id)))

(defun log-esi-request-error (method path error-message &key status-code
                                                              retry-count
                                                              character-id
                                                              response-body)
  "Log an ESI request error with debugging context.

METHOD: HTTP method keyword
PATH: ESI endpoint path
ERROR-MESSAGE: Error description
STATUS-CODE: HTTP status code (NIL for network errors)
RETRY-COUNT: Number of retries attempted
CHARACTER-ID: Associated character ID
RESPONSE-BODY: Error response body (truncated for logging)"
  (log-event :error
             (format nil "ESI error ~A ~A: ~A~@[ (HTTP ~D)~]~@[ retry=~D~]"
                     (string-downcase (symbol-name method))
                     path error-message status-code retry-count)
             :source :http-client
             :method (string-downcase (symbol-name method))
             :path path
             :status status-code
             :error-message error-message
             :retry-count retry-count
             :character-id character-id
             :response-body (truncate-body-for-log response-body 200)))

;;; ---------------------------------------------------------------------------
;;; Rate limit event logging
;;; ---------------------------------------------------------------------------

(defun log-rate-limit-status (error-limit-remain error-limit-reset
                              &key endpoint)
  "Log current ESI error rate limit status.
Only logs when the limit is getting low (below 50).

ERROR-LIMIT-REMAIN: Remaining error budget
ERROR-LIMIT-RESET: Seconds until reset
ENDPOINT: The endpoint that triggered this check"
  (when (and error-limit-remain (< error-limit-remain 50))
    (let ((level (cond
                   ((< error-limit-remain 10) :error)
                   ((< error-limit-remain 20) :warn)
                   (t :info))))
      (log-event level
                 (format nil "ESI error limit: ~D remaining, resets in ~Ds"
                         error-limit-remain error-limit-reset)
                 :source :rate-limiter
                 :error-limit-remain error-limit-remain
                 :error-limit-reset error-limit-reset
                 :endpoint endpoint))))

(defun log-rate-limit-exceeded (&key endpoint retry-after
                                     error-limit-remain
                                     character-id)
  "Log a rate limit exceeded event (HTTP 420).

ENDPOINT: The rate-limited endpoint
RETRY-AFTER: Seconds to wait before retrying
ERROR-LIMIT-REMAIN: Remaining error budget
CHARACTER-ID: Character that triggered the limit"
  (log-event :warn "ESI rate limit exceeded (420)"
             :source :rate-limiter
             :endpoint endpoint
             :retry-after retry-after
             :error-limit-remain error-limit-remain
             :character-id character-id))

(defun log-rate-limit-backoff (endpoint delay-seconds &key reason
                                                           character-id)
  "Log a rate limit backoff event.

ENDPOINT: The endpoint being throttled
DELAY-SECONDS: Duration of the backoff
REASON: Why the backoff was triggered
CHARACTER-ID: Associated character"
  (log-event :info (format nil "Rate limit backoff: ~,1Fs for ~A"
                           delay-seconds endpoint)
             :source :rate-limiter
             :endpoint endpoint
             :backoff-seconds delay-seconds
             :reason reason
             :character-id character-id))

(defun log-throttle-status (requests-per-second queue-depth &key
                                                                  bucket-tokens
                                                                  error-budget)
  "Log current throttling system status.

REQUESTS-PER-SECOND: Current request rate
QUEUE-DEPTH: Number of queued requests
BUCKET-TOKENS: Available token bucket tokens
ERROR-BUDGET: Remaining ESI error budget"
  (log-event :debug "Throttle status"
             :source :rate-limiter
             :rps requests-per-second
             :queue-depth queue-depth
             :bucket-tokens bucket-tokens
             :error-budget error-budget))

;;; ---------------------------------------------------------------------------
;;; Authentication event logging
;;; ---------------------------------------------------------------------------

(defun log-auth-token-refresh (character-id &key success-p
                                                 scopes-count
                                                 expires-in
                                                 error-message)
  "Log a token refresh attempt and its outcome.

CHARACTER-ID: The character whose token was refreshed
SUCCESS-P: Whether the refresh succeeded
SCOPES-COUNT: Number of scopes on the new token
EXPIRES-IN: Seconds until the new token expires
ERROR-MESSAGE: Error message if refresh failed"
  (if success-p
      (log-event :info
                 (format nil "Token refreshed for character ~A (expires in ~Ds)"
                         character-id expires-in)
                 :source :auth
                 :character-id character-id
                 :scopes-count scopes-count
                 :expires-in expires-in)
      (log-event :error
                 (format nil "Token refresh failed for character ~A: ~A"
                         character-id error-message)
                 :source :auth
                 :character-id character-id
                 :error-message error-message)))

(defun log-auth-scope-check (character-id required-scopes &key
                                                                (granted-scopes nil)
                                                                sufficient-p
                                                                missing-scopes)
  "Log a scope validation check.

CHARACTER-ID: The character being checked
REQUIRED-SCOPES: Scopes required by the endpoint
GRANTED-SCOPES: Scopes the token actually has
SUFFICIENT-P: Whether the check passed
MISSING-SCOPES: List of scopes that are missing"
  (declare (ignore granted-scopes))
  (if sufficient-p
      (log-event :trace "Scope check passed"
                 :source :auth
                 :character-id character-id
                 :required-count (length required-scopes))
      (log-event :warn
                 (format nil "Insufficient scopes for character ~A: missing ~{~A~^, ~}"
                         character-id missing-scopes)
                 :source :auth
                 :character-id character-id
                 :required-scopes (format nil "~{~A~^, ~}" required-scopes)
                 :missing-scopes (format nil "~{~A~^, ~}" missing-scopes))))

(defun log-auth-event (event-type character-id &key message details)
  "Log a general authentication event.

EVENT-TYPE: Keyword describing the event (:login, :logout, :token-expired, etc.)
CHARACTER-ID: Associated character
MESSAGE: Human-readable description
DETAILS: Additional structured data plist"
  (let ((level (case event-type
                 ((:login :token-stored) :info)
                 ((:logout :token-revoked) :info)
                 ((:token-expired :token-invalid) :warn)
                 ((:auth-error :sso-error) :error)
                 (t :info))))
    (apply #'log-event level
           (or message (format nil "Auth event: ~A" event-type))
           :source :auth
           :event-type (string-downcase (symbol-name event-type))
           :character-id character-id
           (or details '()))))

;;; ---------------------------------------------------------------------------
;;; Cache event logging
;;; ---------------------------------------------------------------------------

(defun log-cache-hit (cache-key &key cache-layer ttl-remaining
                                     endpoint character-id)
  "Log a cache hit event.

CACHE-KEY: The cache key that was hit
CACHE-LAYER: Which cache layer served the hit (:memory, :database, :etag)
TTL-REMAINING: Seconds until the cached entry expires
ENDPOINT: The ESI endpoint
CHARACTER-ID: Associated character"
  (log-event :trace "Cache hit"
             :source :cache
             :cache-key (truncate-body-for-log cache-key 100)
             :cache-layer (when cache-layer
                            (string-downcase (symbol-name cache-layer)))
             :ttl-remaining ttl-remaining
             :endpoint endpoint
             :character-id character-id))

(defun log-cache-miss (cache-key &key endpoint character-id reason)
  "Log a cache miss event.

CACHE-KEY: The cache key that missed
ENDPOINT: The ESI endpoint
CHARACTER-ID: Associated character
REASON: Why the miss occurred (:expired, :not-found, :invalidated)"
  (log-event :trace "Cache miss"
             :source :cache
             :cache-key (truncate-body-for-log cache-key 100)
             :endpoint endpoint
             :character-id character-id
             :reason (when reason
                       (string-downcase (symbol-name reason)))))

(defun log-cache-store (cache-key &key cache-layer ttl etag
                                       endpoint character-id
                                       size-bytes)
  "Log a cache store event.

CACHE-KEY: The cache key being stored
CACHE-LAYER: Which cache layer (:memory, :database)
TTL: Time-to-live in seconds
ETAG: ETag value being cached
ENDPOINT: The ESI endpoint
CHARACTER-ID: Associated character
SIZE-BYTES: Size of the cached value"
  (log-event :trace "Cache store"
             :source :cache
             :cache-key (truncate-body-for-log cache-key 100)
             :cache-layer (when cache-layer
                            (string-downcase (symbol-name cache-layer)))
             :ttl ttl
             :etag etag
             :endpoint endpoint
             :character-id character-id
             :size-bytes size-bytes))

(defun log-cache-invalidation (cache-key &key reason endpoint
                                              affected-keys)
  "Log a cache invalidation event.

CACHE-KEY: The primary key being invalidated
REASON: Why the invalidation occurred (:write, :manual, :expired)
ENDPOINT: The endpoint that triggered invalidation
AFFECTED-KEYS: Count of related keys also invalidated"
  (log-event :debug "Cache invalidation"
             :source :cache
             :cache-key (truncate-body-for-log cache-key 100)
             :reason (when reason
                       (string-downcase (symbol-name reason)))
             :endpoint endpoint
             :affected-keys affected-keys))

(defun log-cache-etag-revalidation (endpoint &key etag result
                                                   character-id)
  "Log an ETag-based cache revalidation attempt.

ENDPOINT: The ESI endpoint being revalidated
ETAG: The ETag value sent in If-None-Match
RESULT: :not-modified (304) or :updated (200)
CHARACTER-ID: Associated character"
  (log-event :debug
             (format nil "ETag revalidation: ~A => ~A" endpoint result)
             :source :cache
             :endpoint endpoint
             :etag etag
             :revalidation-result (when result
                                    (string-downcase (symbol-name result)))
             :character-id character-id))

(defun log-cache-statistics (hit-count miss-count &key hit-rate
                                                        memory-entries
                                                        db-entries
                                                        etag-entries)
  "Log periodic cache statistics summary.

HIT-COUNT: Total cache hits
MISS-COUNT: Total cache misses
HIT-RATE: Hit rate as a percentage
MEMORY-ENTRIES: Number of entries in memory cache
DB-ENTRIES: Number of entries in database cache
ETAG-ENTRIES: Number of ETag entries"
  (log-event :info
             (format nil "Cache stats: ~D hits, ~D misses (~,1F% hit rate)"
                     hit-count miss-count (or hit-rate 0.0))
             :source :cache
             :hit-count hit-count
             :miss-count miss-count
             :hit-rate hit-rate
             :memory-entries memory-entries
             :db-entries db-entries
             :etag-entries etag-entries))

;;; ---------------------------------------------------------------------------
;;; Circuit breaker event logging
;;; ---------------------------------------------------------------------------

(defun log-circuit-breaker-state-change (name old-state new-state
                                         &key failure-count endpoint)
  "Log a circuit breaker state transition.

NAME: Circuit breaker name
OLD-STATE: Previous state (:closed, :open, :half-open)
NEW-STATE: New state
FAILURE-COUNT: Number of failures that triggered the transition
ENDPOINT: Associated endpoint"
  (let ((level (case new-state
                 (:open :warn)
                 (:half-open :info)
                 (:closed :info)
                 (t :info))))
    (log-event level
               (format nil "Circuit breaker ~A: ~A -> ~A"
                       name old-state new-state)
               :source :circuit-breaker
               :breaker-name name
               :old-state (string-downcase (symbol-name old-state))
               :new-state (string-downcase (symbol-name new-state))
               :failure-count failure-count
               :endpoint endpoint)))

;;; ---------------------------------------------------------------------------
;;; Middleware logging integration
;;; ---------------------------------------------------------------------------

(defun make-structured-logging-request-fn ()
  "Return a request middleware function for structured ESI logging.
This function is intended to be used by eve-gate.core when constructing
the structured logging middleware via MAKE-MIDDLEWARE.

The function:
  - Logs outgoing request details at DEBUG level
  - Stamps the request start time for latency tracking
  - Generates a request ID if not present in context

Returns a function (request-context) -> request-context."
  (lambda (ctx)
    (when (log-level-active-p :debug)
      (log-esi-request (getf ctx :method)
                       (getf ctx :path)
                       :headers (getf ctx :headers)
                       :has-auth-p (not (null
                                         (assoc "Authorization"
                                                (getf ctx :headers)
                                                :test #'string-equal)))))
    ;; Stamp request start time
    (setf (getf ctx :request-start-time) (get-internal-real-time))
    ;; Generate and attach request ID if not present
    (unless *log-request-id*
      (setf (getf ctx :generated-request-id) (generate-request-id)))
    ctx))

(defun make-structured-logging-response-fn (status-accessor)
  "Return a response middleware function for structured ESI logging.
STATUS-ACCESSOR is a function (response) -> integer that extracts the
HTTP status code from the response object.

The function logs the completed response with timing and metadata.

Returns a function (response request-context) -> response."
  (lambda (response ctx)
    (let* ((start-time (getf ctx :request-start-time))
           (latency-ms (when start-time
                         (* (/ (- (get-internal-real-time) start-time)
                               (float internal-time-units-per-second))
                            1000.0))))
      (log-esi-response (getf ctx :method)
                        (getf ctx :path)
                        (funcall status-accessor response)
                        :latency-ms latency-ms))
    response))
