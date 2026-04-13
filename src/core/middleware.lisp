;;;; middleware.lisp - Request/response middleware pipeline for eve-gate
;;;;
;;;; Implements a composable middleware system for HTTP request/response
;;;; processing. Each middleware is a named unit with optional request and
;;;; response transformation functions, a priority for ordering, and an
;;;; enabled flag for runtime toggling.
;;;;
;;;; Middleware is applied in priority order:
;;;;   - Request middleware runs lowest-priority-first (outermost first)
;;;;   - Response middleware runs highest-priority-first (innermost first)
;;;;
;;;; This matches the typical "onion" model where the first middleware added
;;;; is the outermost layer.
;;;;
;;;; Built-in middleware covers the essential ESI concerns:
;;;;   - Headers: Standard ESI headers and datasource
;;;;   - Logging: Request/response logging at configurable detail
;;;;   - JSON: Content-type negotiation for JSON
;;;;   - Error: ESI deprecation warnings and error decoration
;;;;   - Rate limit tracking: Monitors X-ESI-Error-Limit-* headers
;;;;
;;;; Design: Middleware functions are pure transformations on request contexts
;;;; (plists) and response structs. Side effects (logging) are confined to
;;;; specific middleware that opts into them.

(in-package #:eve-gate.core)

;;; ---------------------------------------------------------------------------
;;; Middleware structure
;;; ---------------------------------------------------------------------------

(defstruct (middleware (:constructor %make-middleware))
  "A named unit of request/response processing in the middleware pipeline.

Slots:
  NAME: Keyword identifying this middleware (e.g., :headers, :logging)
  PRIORITY: Integer ordering value. Lower runs first on request, last on response. (default: 100)
  ENABLED-P: Whether this middleware is active (default: T)
  REQUEST-FN: Function (request-context) -> request-context, or NIL
  RESPONSE-FN: Function (response request-context) -> response, or NIL"
  (name :unnamed :type keyword)
  (priority 100 :type integer)
  (enabled-p t :type boolean)
  (request-fn nil :type (or null function))
  (response-fn nil :type (or null function)))

(defun make-middleware (&key (name :unnamed)
                             (priority 100)
                             (enabled t)
                             request-fn
                             response-fn)
  "Create a middleware component for the request/response pipeline.

NAME: Keyword identifier (e.g., :headers, :logging)
PRIORITY: Integer ordering; lower values run earlier on request (default: 100)
ENABLED: Whether the middleware is initially active (default: T)
REQUEST-FN: Function that transforms a request context plist.
            Signature: (request-context) -> request-context
RESPONSE-FN: Function that transforms a response.
             Signature: (response request-context) -> response

RETURNS: A middleware struct.

EXAMPLE:
  (make-middleware :name :custom-header
                  :priority 10
                  :request-fn (lambda (ctx)
                                (push '(\"X-Custom\" . \"value\")
                                      (getf ctx :headers))
                                ctx))"
  (%make-middleware
   :name name
   :priority priority
   :enabled-p enabled
   :request-fn request-fn
   :response-fn response-fn))

;;; ---------------------------------------------------------------------------
;;; Middleware stack operations
;;; ---------------------------------------------------------------------------

(defun make-middleware-stack (&rest middleware-list)
  "Create an ordered middleware stack from the given middleware components.
Sorts by priority (ascending) so that lower-priority middleware runs first on requests.

MIDDLEWARE-LIST: Middleware structs to include in the stack.

Returns a sorted list of middleware."
  (sort (copy-list middleware-list) #'< :key #'middleware-priority))

(defun add-middleware (stack middleware)
  "Add MIDDLEWARE to STACK, maintaining priority ordering.
If a middleware with the same name already exists, it is replaced.

STACK: Existing middleware list
MIDDLEWARE: Middleware struct to add

Returns a new sorted middleware list."
  (let ((filtered (remove (middleware-name middleware) stack
                          :key #'middleware-name)))
    (sort (cons middleware (copy-list filtered))
          #'< :key #'middleware-priority)))

(defun remove-middleware (stack name)
  "Remove the middleware named NAME from STACK.

STACK: Existing middleware list
NAME: Keyword name of the middleware to remove

Returns a new middleware list without the named middleware."
  (remove name stack :key #'middleware-name))

(defun find-middleware (stack name)
  "Find and return the middleware named NAME in STACK, or NIL.

STACK: Middleware list to search
NAME: Keyword name to find"
  (find name stack :key #'middleware-name))

(defun list-middleware (stack)
  "Return a summary of the middleware stack for REPL inspection.
Returns a list of (name priority enabled-p) triples.

STACK: Middleware list

Example:
  (list-middleware (http-client-middleware-stack client))
  => ((:HEADERS 10 T) (:LOGGING 20 T) (:JSON 30 T))"
  (mapcar (lambda (mw)
            (list (middleware-name mw)
                  (middleware-priority mw)
                  (middleware-enabled-p mw)))
          stack))

;;; ---------------------------------------------------------------------------
;;; Middleware pipeline execution
;;; ---------------------------------------------------------------------------

(defun apply-request-middleware (stack request-context)
  "Run all enabled request middleware on REQUEST-CONTEXT in priority order.
Each middleware's request-fn receives the context and must return a
(possibly modified) context.

STACK: Sorted middleware list
REQUEST-CONTEXT: Plist with :method, :uri, :path, :headers, :content, :client

Returns the transformed request context."
  (reduce (lambda (ctx mw)
            (if (and (middleware-enabled-p mw)
                     (middleware-request-fn mw))
                (handler-case
                    (funcall (middleware-request-fn mw) ctx)
                  (error (e)
                    (log-warn "Middleware ~A request-fn error: ~A"
                              (middleware-name mw) e)
                    ctx))
                ctx))
          stack
          :initial-value request-context))

(defun apply-response-middleware (stack response request-context)
  "Run all enabled response middleware on RESPONSE in reverse priority order.
Each middleware's response-fn receives the response and request context,
and must return a (possibly modified) response.

STACK: Sorted middleware list
RESPONSE: An esi-response struct
REQUEST-CONTEXT: The original request context plist

Returns the transformed response."
  (reduce (lambda (resp mw)
            (if (and (middleware-enabled-p mw)
                     (middleware-response-fn mw))
                (handler-case
                    (funcall (middleware-response-fn mw) resp request-context)
                  (error (e)
                    (log-warn "Middleware ~A response-fn error: ~A"
                              (middleware-name mw) e)
                    resp))
                resp))
          (reverse stack)
          :initial-value response))

;;; ---------------------------------------------------------------------------
;;; Macro for temporary middleware
;;; ---------------------------------------------------------------------------

(defmacro with-middleware ((client-form &rest middleware-forms) &body body)
  "Execute BODY with temporary middleware added to CLIENT-FORM's middleware stack.
The original middleware stack is restored after BODY completes (even on error).

CLIENT-FORM: Expression evaluating to an http-client struct
MIDDLEWARE-FORMS: Expressions evaluating to middleware structs to temporarily add

EXAMPLE:
  (with-middleware (client
                    (make-middleware :name :debug
                                    :priority 0
                                    :request-fn #'debug-request))
    (http-request client \"/v5/status/\"))"
  (let ((client-var (gensym "CLIENT"))
        (original-stack (gensym "ORIGINAL-STACK")))
    `(let* ((,client-var ,client-form)
            (,original-stack (http-client-middleware-stack ,client-var)))
       (unwind-protect
            (progn
              (setf (http-client-middleware-stack ,client-var)
                    (reduce #'add-middleware
                            (list ,@middleware-forms)
                            :initial-value ,original-stack))
              ,@body)
         (setf (http-client-middleware-stack ,client-var)
               ,original-stack)))))

;;; ---------------------------------------------------------------------------
;;; Built-in middleware: Standard ESI headers
;;; ---------------------------------------------------------------------------

(defun make-headers-middleware (&key (datasource "tranquility")
                                     (language "en")
                                     extra-headers)
  "Create middleware that ensures standard ESI headers on every request.

DATASOURCE: ESI datasource string (default: \"tranquility\")
LANGUAGE: Accept-Language value (default: \"en\")
EXTRA-HEADERS: Additional alist of headers to include

This middleware runs at priority 10 (early) to establish base headers
before other middleware might modify them."
  (make-middleware
   :name :headers
   :priority 10
   :request-fn
   (lambda (ctx)
     (let* ((current-headers (getf ctx :headers))
            (esi-headers `(("X-ESI-Datasource" . ,datasource)
                           ("Accept-Language" . ,language)
                           ,@extra-headers))
            ;; Only add headers that aren't already set
            (new-headers (loop for (name . value) in esi-headers
                               unless (assoc name current-headers :test #'string-equal)
                               collect (cons name value))))
       (setf (getf ctx :headers) (append current-headers new-headers))
       ctx))))

;;; ---------------------------------------------------------------------------
;;; Built-in middleware: Request/Response logging
;;; ---------------------------------------------------------------------------

(defun make-logging-middleware (&key (log-request t)
                                     (log-response t)
                                     (log-headers nil)
                                     (log-body nil)
                                     (timing t))
  "Create middleware that logs HTTP request/response information.

LOG-REQUEST: Log outgoing request summary (default: T)
LOG-RESPONSE: Log incoming response summary (default: T)
LOG-HEADERS: Include headers in log output (default: NIL, verbose)
LOG-BODY: Include body excerpt in log output (default: NIL, very verbose)
TIMING: Track and log request duration (default: T)

This middleware runs at priority 20 (early, but after headers)."
  (make-middleware
   :name :logging
   :priority 20
   :request-fn
   (lambda (ctx)
     (when log-request
       (log-debug "ESI ~A ~A" (getf ctx :method) (getf ctx :uri))
       (when log-headers
         (log-debug "  Headers: ~{~A: ~A~^, ~}"
                    (loop for (k . v) in (getf ctx :headers)
                          collect k collect v))))
     ;; Stamp the request start time for duration tracking
     (when timing
       (setf (getf ctx :request-start-time) (get-internal-real-time)))
     ctx)
   :response-fn
   (lambda (response ctx)
     (when log-response
       (let ((duration (when (and timing (getf ctx :request-start-time))
                         (/ (- (get-internal-real-time)
                               (getf ctx :request-start-time))
                            (float internal-time-units-per-second)))))
         (log-debug "ESI ~A ~A => ~D~@[ (~,3Fs)~]"
                    (getf ctx :method)
                    (getf ctx :path)
                    (esi-response-status response)
                    duration)
         (when log-headers
           (log-debug "  Response headers: ~A" (esi-response-headers response)))
         (when (and log-body (esi-response-raw-body response))
           (let ((body-preview (if (> (length (esi-response-raw-body response)) 200)
                                   (subseq (esi-response-raw-body response) 0 200)
                                   (esi-response-raw-body response))))
             (log-debug "  Body: ~A..." body-preview)))))
     response)))

;;; ---------------------------------------------------------------------------
;;; Built-in middleware: JSON content type
;;; ---------------------------------------------------------------------------

(defun make-json-middleware ()
  "Create middleware that sets Content-Type to application/json for requests with body content.
This middleware runs at priority 30."
  (make-middleware
   :name :json
   :priority 30
   :request-fn
   (lambda (ctx)
     (when (getf ctx :content)
       (let ((headers (getf ctx :headers)))
         (unless (assoc "Content-Type" headers :test #'string-equal)
           (setf (getf ctx :headers)
                 (cons '("Content-Type" . "application/json")
                       headers)))
         ;; Serialize content to JSON string if it's a hash-table or list
         (let ((content (getf ctx :content)))
           (when (or (hash-table-p content)
                     (and (not (stringp content))
                          (not (typep content '(vector (unsigned-byte 8))))
                          (listp content)))
             (setf (getf ctx :content)
                   (com.inuoe.jzon:stringify content))))))
     ctx)))

;;; ---------------------------------------------------------------------------
;;; Built-in middleware: ESI error decoration and deprecation warnings
;;; ---------------------------------------------------------------------------

(defun make-error-middleware ()
  "Create middleware that processes ESI-specific response metadata.
Checks for:
  - Deprecation warnings in the 'warning' header
  - X-ESI-Error-Limit headers for rate limit awareness

This middleware runs at priority 90 (late in pipeline, after most processing)."
  (make-middleware
   :name :error-decoration
   :priority 90
   :response-fn
   (lambda (response ctx)
     (declare (ignore ctx))
     (let ((headers (esi-response-headers response)))
       (when (hash-table-p headers)
         ;; Check for deprecation warnings
         (when-let ((warning-header (gethash "warning" headers)))
           (warn 'esi-deprecation-warning
                 :message warning-header
                 :endpoint (esi-response-uri response)))
         ;; Log error limit status when getting low
         (multiple-value-bind (etag expires pages error-remain error-reset)
             (extract-esi-metadata headers)
           (declare (ignore etag expires pages))
           (when (and error-remain (< error-remain 20))
             (log-warn "ESI error limit low: ~D remaining, resets in ~D seconds"
                       error-remain (or error-reset "?"))))))
     response)))

;;; ---------------------------------------------------------------------------
;;; Built-in middleware: Rate limit tracking
;;; ---------------------------------------------------------------------------

(defun make-rate-limit-tracking-middleware (&key (callback nil))
  "Create middleware that extracts and tracks ESI rate limiting headers.
This middleware reads X-ESI-Error-Limit-Remain and X-ESI-Error-Limit-Reset
from every response and optionally calls CALLBACK with the values.

CALLBACK: Optional function (error-limit-remain error-limit-reset) called
          after each response with rate limit info. Useful for feeding
          a rate limiter component.

This middleware runs at priority 95 (very late, observational only)."
  (make-middleware
   :name :rate-limit-tracking
   :priority 95
   :response-fn
   (lambda (response ctx)
     (declare (ignore ctx))
     (let ((headers (esi-response-headers response)))
       (when (hash-table-p headers)
         (let ((remain (when-let ((s (gethash "x-esi-error-limit-remain" headers)))
                         (parse-integer s :junk-allowed t)))
               (reset (when-let ((s (gethash "x-esi-error-limit-reset" headers)))
                        (parse-integer s :junk-allowed t))))
           (when (and callback remain)
             (funcall callback remain reset)))))
     response)))

;;; ---------------------------------------------------------------------------
;;; Default middleware stack constructor
;;; ---------------------------------------------------------------------------

(defun make-default-middleware-stack (&key (datasource "tranquility")
                                          (logging t)
                                          (log-headers nil)
                                          (log-body nil)
                                          rate-limit-callback)
  "Create the standard middleware stack for ESI communication.
Includes all built-in middleware with sensible defaults.

DATASOURCE: ESI datasource (default: \"tranquility\")
LOGGING: Enable request/response logging (default: T)
LOG-HEADERS: Include headers in log output (default: NIL)
LOG-BODY: Include body excerpts in log output (default: NIL)
RATE-LIMIT-CALLBACK: Function to receive rate limit updates

Returns a sorted middleware stack list.

EXAMPLE:
  (make-http-client :middleware (make-default-middleware-stack))
  (make-http-client :middleware (make-default-middleware-stack
                                :logging nil
                                :datasource \"singularity\"))"
  (make-middleware-stack
   (make-headers-middleware :datasource datasource)
   (make-logging-middleware :log-request logging
                           :log-response logging
                           :log-headers log-headers
                           :log-body log-body)
   (make-json-middleware)
   (make-error-middleware)
   (make-rate-limit-tracking-middleware :callback rate-limit-callback)))
