;;;; http-client.lisp - ESI-specific HTTP client wrapping dexador
;;;;
;;;; Provides the core HTTP client for communicating with the EVE Swagger
;;;; Interface (ESI). Wraps dexador with ESI-specific configuration including
;;;; standard headers, connection pooling, timeouts, and middleware integration.
;;;;
;;;; The http-client struct holds all configuration state, and the primary
;;;; entry point HTTP-REQUEST handles:
;;;;   - Building full URIs from ESI base URL + endpoint paths
;;;;   - Merging default headers with per-request overrides
;;;;   - Running the middleware pipeline (request → dexador → response)
;;;;   - Translating dexador conditions to ESI-specific conditions
;;;;   - Retry logic for transient failures
;;;;
;;;; Design: The client is a pure data structure; all HTTP I/O is confined
;;;; to HTTP-REQUEST. This makes the client easy to test and inspect at the REPL.

(in-package #:eve-gate.core)

;;; ---------------------------------------------------------------------------
;;; Configuration defaults
;;; ---------------------------------------------------------------------------

(defparameter *esi-base-url* "https://esi.evetech.net/latest"
  "Base URL for the EVE Swagger Interface including version path.
This is the Tranquility (main) server endpoint using the 'latest' stable route.
Change to 'https://esi.evetech.net/dev' for development endpoints.")

(defparameter *user-agent* "eve-gate/0.1.0 (Common Lisp; +https://github.com/fade/eve-gate)"
  "User-Agent header sent with all ESI requests.
ESI best practices recommend identifying your application.")

(defparameter *default-timeout* 30
  "Default HTTP request timeout in seconds.")

(defparameter *default-retries* 3
  "Default number of retry attempts for transient failures.")

(defparameter *esi-default-headers*
  '(("Accept" . "application/json")
    ("Accept-Language" . "en")
    ("Cache-Control" . "no-cache"))
  "Default HTTP headers included with every ESI request.
User-Agent is added separately from client configuration.")

;;; ---------------------------------------------------------------------------
;;; HTTP Client structure
;;; ---------------------------------------------------------------------------

(defstruct (http-client (:constructor %make-http-client))
  "HTTP client configured for ESI API communication.

Holds connection parameters, default headers, middleware stack, and
retry configuration. Create with MAKE-HTTP-CLIENT.

Slots:
  BASE-URL: Root URL for ESI (default: *esi-base-url*)
  USER-AGENT: User-Agent header value
  DEFAULT-HEADERS: Alist of headers sent with every request
  CONNECT-TIMEOUT: TCP connection timeout in seconds
  READ-TIMEOUT: Response read timeout in seconds
  MAX-RETRIES: Maximum retry attempts for transient errors
  USE-CONNECTION-POOL-P: Whether to use dexador's connection pool
  MIDDLEWARE-STACK: Ordered list of middleware for request/response processing
  REQUEST-HOOK: Optional function called before each request (for rate limiting)
  RESPONSE-HOOK: Optional function called after each response (for rate limit tracking)"
  (base-url *esi-base-url* :type string)
  (user-agent *user-agent* :type string)
  (default-headers (copy-alist *esi-default-headers*) :type list)
  (connect-timeout 10 :type (integer 1))
  (read-timeout *default-timeout* :type (integer 1))
  (max-retries *default-retries* :type (integer 0))
  (use-connection-pool-p t :type boolean)
  (middleware-stack nil :type list)
  (request-hook nil :type (or null function))
  (response-hook nil :type (or null function)))

(defun make-http-client (&key (base-url *esi-base-url*)
                              (user-agent *user-agent*)
                              (headers nil headers-supplied-p)
                              (connect-timeout 10)
                              (timeout *default-timeout*)
                              (retries *default-retries*)
                              (use-connection-pool t)
                              middleware
                              request-hook
                              response-hook)
  "Create a new HTTP client configured for ESI API communication.

KEYWORD ARGUMENTS:
  BASE-URL: Root URL for ESI API (default: *esi-base-url*)
  USER-AGENT: Application identifier (default: *user-agent*)
  HEADERS: Additional default headers (alist). Merged with *esi-default-headers*.
  CONNECT-TIMEOUT: TCP connection timeout in seconds (default: 10)
  TIMEOUT: Response read timeout in seconds (default: *default-timeout*)
  RETRIES: Max retry attempts for transient errors (default: *default-retries*)
  USE-CONNECTION-POOL: Use dexador's connection pool (default: T)
  MIDDLEWARE: Initial middleware stack (list of middleware structs)
  REQUEST-HOOK: Function called with (method uri headers) before each request
  RESPONSE-HOOK: Function called with (status headers) after each response

RETURNS: An http-client struct

EXAMPLE:
  ;; Basic client with defaults
  (make-http-client)

  ;; Client with custom timeout and auth header
  (make-http-client :timeout 60
                    :headers '((\"Authorization\" . \"Bearer TOKEN\")))"
  (let ((merged-headers (merge-headers *esi-default-headers*
                                       (when headers-supplied-p headers))))
    (%make-http-client
     :base-url (string-right-trim "/" base-url)
     :user-agent user-agent
     :default-headers merged-headers
     :connect-timeout connect-timeout
     :read-timeout timeout
     :max-retries retries
     :use-connection-pool-p use-connection-pool
     :middleware-stack (or middleware nil)
     :request-hook request-hook
     :response-hook response-hook)))

;;; ---------------------------------------------------------------------------
;;; Header management (pure functions)
;;; ---------------------------------------------------------------------------

(defun merge-headers (base-headers &rest override-header-lists)
  "Merge multiple alists of HTTP headers, later values overriding earlier ones.
Header names are compared case-insensitively.

BASE-HEADERS: Alist of default header pairs
OVERRIDE-HEADER-LISTS: Additional alists whose values take precedence

Returns a fresh alist with merged headers.

Example:
  (merge-headers '((\"Accept\" . \"text/html\"))
                 '((\"Accept\" . \"application/json\")
                   (\"X-Custom\" . \"value\")))
  => ((\"Accept\" . \"application/json\") (\"X-Custom\" . \"value\"))"
  (let ((result (copy-alist base-headers)))
    (dolist (overrides override-header-lists result)
      (when overrides
        (dolist (pair overrides)
          (let ((existing (assoc (car pair) result :test #'string-equal)))
            (if existing
                (setf (cdr existing) (cdr pair))
                (push pair result))))))))

(defun build-request-headers (client &optional extra-headers)
  "Build the complete headers alist for an ESI request.
Combines the client's default headers, User-Agent, and any extra per-request headers.

CLIENT: An http-client struct
EXTRA-HEADERS: Optional alist of additional headers for this request

Returns a fresh alist."
  (merge-headers (http-client-default-headers client)
                 `(("User-Agent" . ,(http-client-user-agent client)))
                 extra-headers))

;;; ---------------------------------------------------------------------------
;;; URI construction (pure)
;;; ---------------------------------------------------------------------------

(defun build-esi-uri (client path &optional query-params)
  "Construct a full ESI URI from the client's base URL, PATH, and optional QUERY-PARAMS.

CLIENT: An http-client struct (for the base URL)
PATH: The endpoint path (e.g., \"/v5/characters/12345/\")
QUERY-PARAMS: Optional alist of query parameters

Returns a URI string.

Example:
  (build-esi-uri client \"/v5/characters/12345/\")
  => \"https://esi.evetech.net/v5/characters/12345/\"

  (build-esi-uri client \"/v5/markets/orders/\"
                 '((\"region_id\" . \"10000002\") (\"type_id\" . \"34\")))
  => \"https://esi.evetech.net/v5/markets/orders/?region_id=10000002&type_id=34\""
  (let* ((base (http-client-base-url client))
         (clean-path (if (and (plusp (length path))
                              (char= (char path 0) #\/))
                         path
                         (concatenate 'string "/" path)))
         (base-uri (concatenate 'string base clean-path)))
    (if query-params
        (concatenate 'string base-uri "?"
                     (format nil "~{~A=~A~^&~}"
                             (loop for (key . value) in query-params
                                   collect key collect value)))
        base-uri)))

;;; ---------------------------------------------------------------------------
;;; Response representation
;;; ---------------------------------------------------------------------------

(defstruct (esi-response (:constructor make-esi-response))
  "Represents a parsed response from the ESI API.

Slots:
  STATUS: HTTP status code (integer)
  HEADERS: Response headers (hash-table with downcased keys)
  BODY: Parsed response body (string, hash-table, or vector from JSON)
  RAW-BODY: Original unparsed body (octets or string)
  URI: Final URI after any redirects
  ETAG: ETag header value, if present
  EXPIRES: Expires header value, if present
  CACHED-P: Whether this response came from cache"
  (status 200 :type integer)
  (headers nil)
  (body nil)
  (raw-body nil)
  (uri nil)
  (etag nil :type (or null string))
  (expires nil :type (or null string))
  (cached-p nil :type boolean))

(defun extract-esi-metadata (headers)
  "Extract ESI-specific metadata from response headers.
Returns multiple values: etag, expires, pages, error-limit-remain, error-limit-reset.

HEADERS: Hash-table of response headers (keys are downcased strings)."
  (when headers
    (values
     (gethash "etag" headers)
     (gethash "expires" headers)
     (when-let ((pages-str (gethash "x-pages" headers)))
       (parse-integer pages-str :junk-allowed t))
     (when-let ((remain-str (gethash "x-esi-error-limit-remain" headers)))
       (parse-integer remain-str :junk-allowed t))
     (when-let ((reset-str (gethash "x-esi-error-limit-reset" headers)))
       (parse-integer reset-str :junk-allowed t)))))

;;; ---------------------------------------------------------------------------
;;; Core request engine
;;; ---------------------------------------------------------------------------

(defun http-request (client path &key (method :get)
                                      headers
                                      content
                                      query-params
                                      bearer-token
                                      (parse-json t)
                                      if-none-match)
  "Send an HTTP request to an ESI endpoint through the middleware pipeline.

This is the primary entry point for all ESI communication. It:
  1. Builds the full URI from the client's base URL and PATH
  2. Merges default headers with per-request headers
  3. Runs request middleware (headers, logging, etc.)
  4. Executes the HTTP request via dexador
  5. Runs response middleware (JSON parsing, error handling, etc.)
  6. Retries on transient errors up to MAX-RETRIES times

CLIENT: An http-client struct
PATH: ESI endpoint path (e.g., \"/v5/characters/12345/\")
METHOD: HTTP method keyword (:get :post :put :delete, default :get)
HEADERS: Per-request headers (alist), merged with client defaults
CONTENT: Request body (string, alist, or octets)
QUERY-PARAMS: Query parameters alist (e.g., '((\"page\" . \"1\")))
BEARER-TOKEN: OAuth2 bearer token string (added to Authorization header)
PARSE-JSON: If T (default), parse response body as JSON
IF-NONE-MATCH: ETag value for conditional requests (If-None-Match header)

Returns an ESI-RESPONSE struct.

Signals:
  ESI-RATE-LIMIT-EXCEEDED: When the error rate limit is hit (420)
  ESI-CLIENT-ERROR: For 4xx errors
  ESI-SERVER-ERROR: For 5xx errors
  ESI-NETWORK-ERROR: For connection/timeout failures

Restarts:
  USE-VALUE: Supply a substitute response
  RETRY: Retry the request

Example:
  (http-request client \"/v5/characters/12345/\")
  (http-request client \"/v5/markets/orders/\"
                :query-params '((\"region_id\" . \"10000002\"))
                :bearer-token token)"
  (let* ((uri (build-esi-uri client path query-params))
         (request-headers (build-request-headers
                           client
                           (append headers
                                   (when bearer-token
                                     `(("Authorization"
                                        . ,(concatenate 'string "Bearer " bearer-token))))
                                   (when if-none-match
                                     `(("If-None-Match" . ,if-none-match))))))
         ;; Build the request context for middleware
         (request-context (list :method method
                                :uri uri
                                :path path
                                :headers request-headers
                                :content content
                                :client client)))
    ;; Apply request middleware 
    (setf request-context
          (apply-request-middleware (http-client-middleware-stack client)
                                   request-context))
    ;; Invoke request hook if present (e.g., rate limiter check)
    (when (http-client-request-hook client)
      (funcall (http-client-request-hook client)
               (getf request-context :method)
               (getf request-context :uri)
               (getf request-context :headers)))
    ;; Execute with retry logic and performance tracking
    (let ((start-time (get-precise-time)))
      (multiple-value-prog1
          (execute-with-retries client request-context parse-json)
        (let ((elapsed-ms (elapsed-milliseconds start-time)))
          (record-metric :http-request-latency elapsed-ms)
          (record-request-completed elapsed-ms))))))

(defun execute-with-retries (client request-context parse-json)
  "Execute an HTTP request with retry logic for transient errors.

CLIENT: An http-client struct (for retry count and response hook)
REQUEST-CONTEXT: Plist with :method, :uri, :headers, :content
PARSE-JSON: Whether to parse the response body as JSON

Returns an ESI-RESPONSE struct."
  (let ((max-retries (http-client-max-retries client))
        (method (getf request-context :method))
        (uri (getf request-context :uri))
        (headers (getf request-context :headers))
        (content (getf request-context :content)))
    (loop for attempt from 0 to max-retries
          do (multiple-value-bind (response retry-p)
                 (execute-single-request client method uri headers content parse-json)
               (cond
                 ;; Success - return immediately
                 ((esi-response-p response)
                  ;; Apply response middleware
                  (let ((processed (apply-response-middleware
                                   (http-client-middleware-stack client)
                                   response request-context)))
                    (return processed)))
                 ;; Retryable error and we have retries left
                 ((and retry-p (< attempt max-retries))
                  (let ((delay (compute-retry-delay attempt response)))
                    (log-warn "ESI request to ~A failed (attempt ~D/~D), retrying in ~,1F seconds"
                              uri (1+ attempt) (1+ max-retries) delay)
                    (sleep delay)))
                 ;; Non-retryable error or out of retries - signal condition
                 (t
                  (log-error "ESI request to ~A failed after ~D attempts"
                             uri (1+ attempt))
                  ;; response here is a plist of error info
                  (signal-esi-error
                   (getf response :status-code)
                   :message (getf response :message)
                   :endpoint (getf request-context :path)
                   :response-body (getf response :body)
                   :response-headers (getf response :headers))))))))

(defun execute-single-request (client method uri headers content parse-json)
  "Execute a single HTTP request via dexador and wrap the result.

Returns two values:
  1. Either an ESI-RESPONSE on success, or a plist of error info on failure
  2. T if the error is retryable, NIL otherwise"
  (handler-case
      (multiple-value-bind (body status response-headers response-uri)
          (dex:request uri
                       :method method
                       :headers headers
                       :content content
                       :connect-timeout (http-client-connect-timeout client)
                       :read-timeout (http-client-read-timeout client)
                       :keep-alive t
                       :use-connection-pool (http-client-use-connection-pool-p client)
                       :force-string t)
        ;; Invoke the response hook if present (e.g., error-limit tracking)
        (when (http-client-response-hook client)
          (funcall (http-client-response-hook client)
                   status response-headers))
        ;; Check for 304 Not Modified (ETag cache hit)
        (if (= status 304)
            (values (make-esi-response
                     :status 304
                     :headers response-headers
                     :body nil
                     :raw-body body
                     :uri response-uri
                     :cached-p t)
                    nil)
            ;; Normal successful response
            (multiple-value-bind (etag expires)
                (extract-esi-metadata response-headers)
              (values (make-esi-response
                       :status status
                       :headers response-headers
                       :body (if (and parse-json body (plusp (length body)))
                                 (parse-json-body body)
                                 body)
                       :raw-body body
                       :uri response-uri
                       :etag etag
                       :expires expires
                       :cached-p nil)
                      nil))))
    ;; Dexador signals conditions for 4xx/5xx, catch and translate
    (dex:http-request-failed (e)
      (let* ((status (dex:response-status e))
             (body (dex:response-body e))
             (resp-headers (dex:response-headers e))
             (retryable (retryable-status-p status)))
        ;; Invoke response hook even on errors (for error-limit tracking)
        (when (http-client-response-hook client)
          (funcall (http-client-response-hook client)
                   status resp-headers))
        (values (list :status-code status
                      :body body
                      :headers resp-headers
                      :message (format nil "HTTP ~D: ~A" status
                                       (or (extract-esi-error-message body)
                                           (princ-to-string e))))
                retryable)))
    ;; Network/timeout errors
    (error (e)
      (values (list :status-code nil
                    :body nil
                    :headers nil
                    :message (format nil "Network error: ~A" e))
              t))))

;;; ---------------------------------------------------------------------------
;;; JSON parsing
;;; ---------------------------------------------------------------------------

(defun parse-json-body (body)
  "Parse a JSON response body string into Lisp data structures.
Uses jzon for parsing. Returns the parsed object (hash-table for objects,
vector for arrays, or primitive values).

BODY: A string containing JSON data

Returns the parsed JSON value, or the original string if parsing fails."
  (handler-case
      (with-metric-timing (:json-parse-time)
        (com.inuoe.jzon:parse body))
    (error (e)
      (log-warn "Failed to parse JSON response: ~A" e)
      body)))

(defun extract-esi-error-message (body)
  "Try to extract an error message from an ESI error response body.
ESI returns errors as JSON with an \"error\" field.

BODY: Response body string

Returns the error message string, or NIL."
  (when (and body (stringp body) (plusp (length body)))
    (handler-case
        (let ((parsed (com.inuoe.jzon:parse body)))
          (when (hash-table-p parsed)
            (gethash "error" parsed)))
      (error () nil))))

;;; ---------------------------------------------------------------------------
;;; Retry delay computation
;;; ---------------------------------------------------------------------------

(defun compute-retry-delay (attempt &optional error-info)
  "Compute the delay in seconds before retrying a failed request.
Uses exponential backoff with jitter. Respects Retry-After header if present.

ATTEMPT: Zero-based attempt number (0 for first retry)
ERROR-INFO: Optional plist with :headers containing response headers

Returns delay in seconds (float)."
  ;; Check for Retry-After header
  (let ((headers (when (listp error-info) (getf error-info :headers))))
    (or (when (hash-table-p headers)
          (when-let ((retry-after (gethash "retry-after" headers)))
            (parse-integer retry-after :junk-allowed t)))
        ;; Exponential backoff: 1s, 2s, 4s, 8s, ... with jitter
        (let* ((base-delay (expt 2 attempt))
               (jitter (* base-delay (random 0.5))))
          (min (+ base-delay jitter) 30.0)))))
