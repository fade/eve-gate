;;;; api-client.lisp - High-level ESI API client
;;;;
;;;; Provides a high-level API client that combines the HTTP client, authentication,
;;;; caching, and generated endpoint functions into a unified interface.
;;;;
;;;; The api-client wraps an http-client with additional ESI-specific functionality:
;;;;   - Automatic OAuth token management for authenticated endpoints
;;;;   - Endpoint registry integration for metadata lookup
;;;;   - Convenience methods for common HTTP verbs
;;;;   - Response type parsing via the generated response-types registry
;;;;
;;;; Design:
;;;;   - Thin wrapper over http-client - delegates actual HTTP to core
;;;;   - Provides the CLIENT argument expected by all generated functions
;;;;   - Integrates with endpoint registry for introspection
;;;;   - Thread-safe: multiple goroutines can share one api-client
;;;;
;;;; Usage:
;;;;   (let ((client (make-api-client)))
;;;;     (get-characters-character-id client 95465499))

(in-package #:eve-gate.api)

;;; ---------------------------------------------------------------------------
;;; API Client structure
;;; ---------------------------------------------------------------------------

(defstruct (api-client (:constructor %make-api-client))
  "High-level ESI API client combining HTTP, auth, and caching.

Wraps an HTTP client with ESI-specific functionality. This is the
primary CLIENT argument passed to all generated API functions.

Slots:
  HTTP-CLIENT: The underlying http-client for HTTP operations
  TOKEN-MANAGER: Optional token-manager for authenticated endpoints
  DEFAULT-TOKEN: Optional pre-set OAuth token string for authentication
  REGISTRY-LOADED-P: Whether the endpoint registry has been populated"
  (http-client nil)
  (token-manager nil)
  (default-token nil :type (or null string))
  (registry-loaded-p nil :type boolean))

(defun make-api-client (&key (base-url *esi-base-url*)
                              (user-agent *user-agent*)
                              (connect-timeout 10)
                              (read-timeout *default-timeout*)
                              (max-retries *default-retries*)
                              token-manager
                              token)
  "Create a new API client for ESI access.

BASE-URL: ESI base URL (default: *esi-base-url*)
USER-AGENT: User-Agent header value
CONNECT-TIMEOUT: TCP connection timeout in seconds
READ-TIMEOUT: Response read timeout in seconds
MAX-RETRIES: Maximum retry attempts for transient failures
TOKEN-MANAGER: Optional token-manager for authenticated endpoints
TOKEN: Optional pre-set OAuth token string

Returns an API-CLIENT struct.

Example:
  ;; Public-only client
  (make-api-client)

  ;; Authenticated client with token
  (make-api-client :token \"your-access-token\")

  ;; Authenticated client with token manager
  (make-api-client :token-manager (make-token-manager ...))"
  (let ((http-client (make-http-client :base-url base-url
                                        :user-agent user-agent
                                        :connect-timeout connect-timeout
                                        :read-timeout read-timeout
                                        :max-retries max-retries)))
    (%make-api-client :http-client http-client
                      :token-manager token-manager
                      :default-token token)))

;;; ---------------------------------------------------------------------------
;;; Generic API call interface
;;; ---------------------------------------------------------------------------

(defun api-call (client operation-id &rest params &key &allow-other-keys)
  "Make a generic API call by operation ID.

CLIENT: An api-client (or http-client)
OPERATION-ID: String operation ID (e.g., \"get_characters_character_id\")
PARAMS: Keyword parameters to pass to the endpoint function

This uses the endpoint registry to find the function and call it.

Returns the result of the endpoint function.

Example:
  (api-call client \"get_characters_character_id\" :character-id 95465499)"
  (let* ((meta (find-endpoint operation-id))
         (fn-name (when meta (getf meta :function-name))))
    (unless meta
      (error 'esi-bad-request
             :message (format nil "Unknown operation ID: ~S" operation-id)))
    (let ((fn-symbol (find-symbol (string-upcase fn-name) :eve-gate.api)))
      (unless (and fn-symbol (fboundp fn-symbol))
        (error 'esi-bad-request
               :message (format nil "Function ~A not found or not bound" fn-name)))
      (apply fn-symbol (resolve-client client) params))))

;;; ---------------------------------------------------------------------------
;;; Convenience HTTP verb methods
;;; ---------------------------------------------------------------------------

(defun api-get (client path &key query-params token)
  "Make a GET request through the API client.

CLIENT: An api-client or http-client
PATH: ESI endpoint path
QUERY-PARAMS: Alist of query parameters
TOKEN: Optional OAuth token (overrides client default)

Returns (VALUES body response)."
  (let* ((resolved (resolve-client client))
         (effective-token (or token (effective-token client))))
    (let ((response (http-request resolved path
                                   :method :get
                                   :query-params query-params
                                   :bearer-token effective-token)))
      (values (esi-response-body response) response))))

(defun api-post (client path &key query-params content token)
  "Make a POST request through the API client.

CLIENT: An api-client or http-client
PATH: ESI endpoint path
QUERY-PARAMS: Alist of query parameters
CONTENT: Request body (will be JSON-stringified)
TOKEN: Optional OAuth token

Returns (VALUES body response)."
  (let* ((resolved (resolve-client client))
         (effective-token (or token (effective-token client)))
         (body-str (when content
                     (com.inuoe.jzon:stringify content))))
    (let ((response (http-request resolved path
                                   :method :post
                                   :query-params query-params
                                   :content body-str
                                   :bearer-token effective-token)))
      (values (esi-response-body response) response))))

(defun api-put (client path &key query-params content token)
  "Make a PUT request through the API client.

CLIENT: An api-client or http-client
PATH: ESI endpoint path
QUERY-PARAMS: Alist of query parameters
CONTENT: Request body (will be JSON-stringified)
TOKEN: Optional OAuth token

Returns (VALUES body response)."
  (let* ((resolved (resolve-client client))
         (effective-token (or token (effective-token client)))
         (body-str (when content
                     (com.inuoe.jzon:stringify content))))
    (let ((response (http-request resolved path
                                   :method :put
                                   :query-params query-params
                                   :content body-str
                                   :bearer-token effective-token)))
      (values (esi-response-body response) response))))

(defun api-delete (client path &key query-params token)
  "Make a DELETE request through the API client.

CLIENT: An api-client or http-client
PATH: ESI endpoint path
QUERY-PARAMS: Alist of query parameters
TOKEN: Optional OAuth token

Returns (VALUES body response)."
  (let* ((resolved (resolve-client client))
         (effective-token (or token (effective-token client))))
    (let ((response (http-request resolved path
                                   :method :delete
                                   :query-params query-params
                                   :bearer-token effective-token)))
      (values (esi-response-body response) response))))

;;; ---------------------------------------------------------------------------
;;; Client resolution utilities
;;; ---------------------------------------------------------------------------

(defun resolve-client (client)
  "Resolve a client argument to an http-client.

Generated functions accept either an api-client or a bare http-client
as their first argument. This function normalizes to an http-client.

CLIENT: An api-client or http-client

Returns an http-client struct."
  (typecase client
    (api-client (api-client-http-client client))
    (http-client client)
    (t (error 'type-error
              :datum client
              :expected-type '(or api-client http-client)))))

(defun effective-token (client)
  "Get the effective OAuth token for a client.

Checks (in order):
  1. Token manager (auto-refreshing)
  2. Default token on the api-client

CLIENT: An api-client

Returns a token string, or NIL for public-only access."
  (typecase client
    (api-client
     (or (when (api-client-token-manager client)
           (handler-case
               (get-valid-access-token (api-client-token-manager client))
             (error () nil)))
         (api-client-default-token client)))
    (t nil)))
