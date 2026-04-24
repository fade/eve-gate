;;;; oauth2.lisp - OAuth 2.0 authentication for EVE SSO via CIAO
;;;;
;;;; Implements the OAuth 2.0 authorization code flow for the EVE Online
;;;; Single Sign-On (SSO) system. Built on top of the CIAO OAuth 2.0 client
;;;; library, this module provides:
;;;;
;;;;   - EVE SSO server configuration (auth, token, verify endpoints)
;;;;   - OAuth client creation with ESI-specific defaults
;;;;   - Authorization URL generation for browser-based login
;;;;   - Authorization code exchange for access/refresh tokens
;;;;   - Token refresh for maintaining long-lived sessions
;;;;   - Authentication middleware for the HTTP request pipeline
;;;;   - Auth-specific condition types for SSO error handling
;;;;
;;;; The EVE SSO uses standard OAuth 2.0 authorization code flow:
;;;;   1. Client generates an authorization URL with requested scopes
;;;;   2. User authenticates at login.eveonline.com in their browser
;;;;   3. EVE SSO redirects back with an authorization code
;;;;   4. Client exchanges the code for access and refresh tokens
;;;;   5. Access token is used in Authorization: Bearer headers
;;;;   6. When access token expires, refresh token obtains a new one
;;;;
;;;; Design: The oauth-client struct holds immutable configuration.
;;;; All mutable token state lives in the token-manager module.
;;;; This module provides pure functions for URL generation and
;;;; middleware construction, with I/O confined to the code exchange
;;;; and token refresh operations (which delegate to CIAO/dexador).

(in-package #:eve-gate.auth)

;;; ---------------------------------------------------------------------------
;;; EVE SSO server configuration
;;; ---------------------------------------------------------------------------

(defparameter *eve-sso-auth-url*
  "https://login.eveonline.com/v2/oauth/authorize"
  "EVE SSO OAuth 2.0 authorization endpoint URL.
Users are directed here to authenticate and authorize scopes.")

(defparameter *eve-sso-token-url*
  "https://login.eveonline.com/v2/oauth/token"
  "EVE SSO OAuth 2.0 token endpoint URL.
Used for exchanging auth codes and refreshing tokens.")

(defparameter *eve-sso-verify-url*
  "https://login.eveonline.com/oauth/verify"
  "EVE SSO token verification endpoint URL.
Returns character information for a valid access token.")

(defparameter *eve-sso-jwks-url*
  "https://login.eveonline.com/oauth/jwks"
  "EVE SSO JSON Web Key Set URL.
Contains the public keys for verifying JWT access tokens.")

(defparameter *eve-sso-revoke-url*
  "https://login.eveonline.com/v2/oauth/revoke"
  "EVE SSO token revocation endpoint URL.
Used to invalidate access or refresh tokens.")

(defparameter *eve-sso-auth-server*
  (make-instance 'ciao:oauth2-auth-server
                 :auth-url *eve-sso-auth-url*
                 :token-url *eve-sso-token-url*)
  "CIAO auth-server instance configured for EVE SSO.
Pre-configured with EVE's authorization and token endpoint URLs.")

(defparameter *default-callback-port* 29170
  "Default local port for the OAuth callback servlet.
Used when no explicit redirect URI is provided. Must match the
callback URL registered with your EVE developer application.")

(defparameter *default-redirect-uri*
  (format nil "http://localhost:~D/oauth/callback" *default-callback-port*)
  "Default OAuth redirect URI for local development.
Must be registered in your EVE developer application settings at
https://developers.eveonline.com/")

;;; ---------------------------------------------------------------------------
;;; Auth-specific conditions  
;;; ---------------------------------------------------------------------------

(define-condition eve-sso-error (esi-error)
  ((sso-error-type :initarg :sso-error-type
                   :initform nil
                   :reader eve-sso-error-type)
   (sso-error-description :initarg :sso-error-description
                          :initform nil
                          :reader eve-sso-error-description))
  (:documentation "Condition signaled for EVE SSO authentication errors.")
  (:report (lambda (condition stream)
             (format stream "EVE SSO Error~@[ (~A)~]: ~A~@[~%~A~]"
                     (eve-sso-error-type condition)
                     (esi-error-message condition)
                     (eve-sso-error-description condition)))))

(define-condition eve-sso-token-expired (eve-sso-error)
  ()
  (:documentation "Condition signaled when an access token has expired and
cannot be automatically refreshed.")
  (:default-initargs :message "Access token expired"))

(define-condition eve-sso-insufficient-scopes (eve-sso-error)
  ((required-scopes :initarg :required-scopes
                    :initform nil
                    :reader eve-sso-required-scopes)
   (granted-scopes :initarg :granted-scopes
                   :initform nil
                   :reader eve-sso-granted-scopes))
  (:documentation "Condition signaled when the token lacks required scopes.")
  (:report (lambda (condition stream)
             (format stream "Insufficient ESI scopes.~%Required: ~{~A~^, ~}~%Granted: ~{~A~^, ~}"
                     (eve-sso-required-scopes condition)
                     (eve-sso-granted-scopes condition)))))

(define-condition eve-sso-token-refresh-failed (eve-sso-error)
  ((original-error :initarg :original-error
                   :initform nil
                   :reader eve-sso-original-error))
  (:documentation "Condition signaled when token refresh fails.")
  (:default-initargs :message "Failed to refresh access token"))

;;; ---------------------------------------------------------------------------
;;; OAuth client structure
;;; ---------------------------------------------------------------------------

(defstruct (oauth-client (:constructor %make-oauth-client))
  "Holds the immutable OAuth 2.0 client configuration for EVE SSO.

Slots:
  CLIENT-ID: The application's client ID from EVE developer portal
  CLIENT-SECRET: The application's client secret
  REDIRECT-URI: The callback URI registered with EVE developer portal
  SCOPES: List of ESI scope strings to request during authorization
  AUTH-SERVER: CIAO auth-server instance for EVE SSO
  CIAO-CLIENT: CIAO oauth2-client instance (derived from client-id/secret)
  CIAO-OAUTH: CIAO oauth2 instance (populated after successful auth)

Create with MAKE-OAUTH-CLIENT."
  (client-id (error "CLIENT-ID is required") :type string :read-only t)
  (client-secret (error "CLIENT-SECRET is required") :type string :read-only t)
  (redirect-uri *default-redirect-uri* :type string :read-only t)
  (scopes nil :type list :read-only t)
  (auth-server *eve-sso-auth-server* :read-only t)
  (ciao-client nil :read-only t)
  (ciao-oauth nil))

(defun make-oauth-client (&key client-id client-secret
                                (redirect-uri *default-redirect-uri*)
                                scopes
                                (auth-server *eve-sso-auth-server*))
  "Create an OAuth client configured for EVE SSO authentication.

CLIENT-ID: Your application's client ID from https://developers.eveonline.com/
CLIENT-SECRET: Your application's secret key
REDIRECT-URI: Callback URI registered with your EVE application
              (default: *default-redirect-uri*)
SCOPES: List of ESI scope strings to request (validated against registry)
AUTH-SERVER: CIAO auth-server instance (default: *eve-sso-auth-server*)

Returns: An oauth-client struct ready for authorization.

Signals an error if CLIENT-ID or CLIENT-SECRET are missing, or if
any scope strings are invalid.

Example:
  (make-oauth-client
   :client-id \"your-client-id\"
   :client-secret \"your-secret\"
   :scopes '(\"esi-skills.read_skills.v1\"
             \"esi-wallet.read_character_wallet.v1\"))"
  (unless (and client-id (plusp (length client-id)))
    (error "CLIENT-ID is required for OAuth authentication"))
  (unless (and client-secret (plusp (length client-secret)))
    (error "CLIENT-SECRET is required for OAuth authentication"))
  ;; Validate scopes against the registry
  (when scopes
    (validate-scopes scopes))
  (let ((ciao-client (make-instance 'ciao:oauth2-client
                                    :id client-id
                                    :secret client-secret)))
    (%make-oauth-client
     :client-id client-id
     :client-secret client-secret
     :redirect-uri redirect-uri
     :scopes (copy-list scopes)
     :auth-server auth-server
     :ciao-client ciao-client
     :ciao-oauth nil)))

;;; ---------------------------------------------------------------------------
;;; Authorization URL generation (pure)
;;; ---------------------------------------------------------------------------

(defun get-authorization-url (oauth-client &key scopes state)
  "Generate the EVE SSO authorization URL for browser-based login.

The user should be directed to this URL to authenticate with EVE SSO.
After authentication, EVE SSO will redirect to the registered callback
URI with an authorization code.

OAUTH-CLIENT: An oauth-client struct
SCOPES: Override the client's default scopes (optional, list of strings)
STATE: Optional opaque state string for CSRF protection

Returns: A URL string for the EVE SSO login page.

Example:
  (get-authorization-url client)
  => \"https://login.eveonline.com/v2/oauth/authorize?response_type=code&client_id=...\"

  (get-authorization-url client
                         :scopes '(\"esi-skills.read_skills.v1\")
                         :state \"random-csrf-token\")"
  (let* ((effective-scopes (or scopes (oauth-client-scopes oauth-client)))
         (auth-url-uri
           (ciao:get-auth-request-url
            (oauth-client-auth-server oauth-client)
            :client (oauth-client-ciao-client oauth-client)
            :scopes effective-scopes
            :redirect-uri (oauth-client-redirect-uri oauth-client)
            :state state)))
    ;; CIAO returns a QURI:URI, render to string
    (quri:render-uri auth-url-uri)))

;;; ---------------------------------------------------------------------------
;;; Authorization code exchange
;;; ---------------------------------------------------------------------------

(defun exchange-code-for-token (oauth-client authorization-code
                                &key (redirect-uri nil redirect-uri-p))
  "Exchange an authorization code for access and refresh tokens.

After the user authenticates at EVE SSO, they are redirected back with
an authorization code. This function exchanges that code for tokens.

OAUTH-CLIENT: An oauth-client struct
AUTHORIZATION-CODE: The code received from EVE SSO redirect
REDIRECT-URI: Override the client's registered redirect URI (rare)

Returns: A token-info plist with keys:
  :ACCESS-TOKEN - The bearer token for API requests
  :REFRESH-TOKEN - Token for obtaining new access tokens
  :EXPIRES-IN - Seconds until the access token expires
  :TOKEN-TYPE - Always \"Bearer\" for EVE SSO
  :SCOPES - List of granted scope strings
  :CHARACTER-ID - EVE character ID (from token verification)
  :CHARACTER-NAME - EVE character name (from token verification)
  :OBTAINED-AT - Universal time when token was obtained

Signals EVE-SSO-ERROR on authentication failure.

Example:
  (exchange-code-for-token client \"auth-code-from-callback\")
  => (:ACCESS-TOKEN \"eyJ...\" :REFRESH-TOKEN \"abc...\" ...)"
  (let ((effective-redirect-uri (if redirect-uri-p
                                    redirect-uri
                                    (oauth-client-redirect-uri oauth-client))))
    (handler-case
        (let* ((now (get-universal-time))
               ;; Use CIAO to exchange the code
               (ciao-oauth (ciao:oauth2/auth-code
                            (oauth-client-auth-server oauth-client)
                            (oauth-client-ciao-client oauth-client)
                            authorization-code
                            :redirect-uri effective-redirect-uri)))
          ;; Store the CIAO oauth2 object on our client for refresh later
          (setf (oauth-client-ciao-oauth oauth-client) ciao-oauth)
          ;; Extract token information
          (let* ((access-token (ciao:get-access-token ciao-oauth :re-acquire? nil))
                 (refresh-token (ciao:get-refresh-token ciao-oauth))
                 (ciao-scopes (slot-value ciao-oauth 'ciao::scopes))
                 (scopes (or (if (listp ciao-scopes) ciao-scopes
                                 (when ciao-scopes (parse-scope-string ciao-scopes)))
                             ;; Fallback: EVE SSO doesn't always return scopes
                             ;; via the OAuth library — extract from the JWT.
                             (extract-jwt-scopes access-token))))
            ;; Verify the token to get character info
            (multiple-value-bind (character-id character-name)
                (verify-access-token access-token)
              (let ((token-info
                      (list :access-token access-token
                            :refresh-token refresh-token
                            :expires-in (compute-expires-in ciao-oauth now)
                            :token-type "Bearer"
                            :scopes scopes
                            :character-id character-id
                            :character-name character-name
                            :obtained-at now)))
                (log-info "EVE SSO: Authenticated as ~A (ID: ~A) with ~D scope~:P"
                          character-name character-id
                          (length (getf token-info :scopes)))
                token-info))))
      (error (e)
        (log-error "EVE SSO authentication failed: ~A" e)
        (error 'eve-sso-error
               :message (format nil "Failed to exchange authorization code: ~A" e)
               :sso-error-type :code-exchange-failed)))))

;;; ---------------------------------------------------------------------------
;;; Token refresh
;;; ---------------------------------------------------------------------------

(defun refresh-access-token (oauth-client &optional current-refresh-token)
  "Obtain a new access token using the refresh token.

EVE SSO access tokens expire after 20 minutes. This function uses
the refresh token to obtain a new access token without requiring
the user to re-authenticate.

OAUTH-CLIENT: An oauth-client struct (must have a CIAO-OAUTH with refresh token)
CURRENT-REFRESH-TOKEN: Optional explicit refresh token to use (overrides
                       the token stored in the CIAO oauth object)

Returns: A token-info plist (same format as EXCHANGE-CODE-FOR-TOKEN).

Signals EVE-SSO-TOKEN-REFRESH-FAILED on failure.

Example:
  (refresh-access-token client)
  => (:ACCESS-TOKEN \"new-eyJ...\" :REFRESH-TOKEN \"new-abc...\" ...)"
  (handler-case
      (let ((now (get-universal-time))
            (ciao-oauth (oauth-client-ciao-oauth oauth-client)))
        ;; If we have an explicit refresh token, set it on the CIAO object
        (when current-refresh-token
          (if ciao-oauth
              (setf (slot-value ciao-oauth 'ciao::refresh-token)
                    current-refresh-token)
              ;; No existing CIAO oauth - create a new one with the refresh token
              (let ((new-oauth (ciao:oauth2/refresh-token
                                (oauth-client-auth-server oauth-client)
                                (oauth-client-ciao-client oauth-client)
                                current-refresh-token)))
                (setf (oauth-client-ciao-oauth oauth-client) new-oauth)
                (setf ciao-oauth new-oauth))))
        (unless ciao-oauth
          (error 'eve-sso-token-refresh-failed
                 :sso-error-description "No OAuth session established. Authenticate first."))
        ;; If we set a refresh token but haven't called refresh yet, do so now
        (unless current-refresh-token
          ;; Let CIAO handle the refresh via its internal machinery
          ;; Force a refresh by requesting the access token with re-acquire
          (ciao:get-access-token ciao-oauth :re-acquire? t))
        ;; Extract the refreshed token information
        (let* ((access-token (ciao:get-access-token ciao-oauth :re-acquire? nil))
               (refresh-token (ciao:get-refresh-token ciao-oauth))
               (ciao-scopes (slot-value ciao-oauth 'ciao::scopes))
               (scopes (or (if (listp ciao-scopes) ciao-scopes
                               (when ciao-scopes (parse-scope-string ciao-scopes)))
                           ;; Fallback: EVE SSO doesn't always return scopes
                           ;; via the OAuth library — extract from the JWT.
                           (extract-jwt-scopes access-token)))
               (token-info
                 (list :access-token access-token
                       :refresh-token refresh-token
                       :expires-in (compute-expires-in ciao-oauth now)
                       :token-type "Bearer"
                       :scopes scopes
                       :obtained-at now)))
          ;; Verify to get character info
          (handler-case
              (multiple-value-bind (character-id character-name)
                  (verify-access-token access-token)
                (setf (getf token-info :character-id) character-id)
                (setf (getf token-info :character-name) character-name))
            (error (e)
              (log-warn "Token verification after refresh failed: ~A" e)))
          (log-info "EVE SSO: Token refreshed, expires in ~D seconds"
                    (getf token-info :expires-in))
          token-info))
    (eve-sso-token-refresh-failed ()
      ;; Re-raise if already our condition
      (error (make-condition 'eve-sso-token-refresh-failed)))
    (error (e)
      (log-error "EVE SSO token refresh failed: ~A" e)
      (error 'eve-sso-token-refresh-failed
             :sso-error-description (format nil "~A" e)
             :original-error e))))

;;; ---------------------------------------------------------------------------
;;; Token verification
;;; ---------------------------------------------------------------------------

(defun verify-access-token (access-token)
  "Verify an access token with EVE SSO and extract character information.

Calls the EVE SSO verify endpoint to confirm the token is valid and
retrieve the associated character information.

ACCESS-TOKEN: A bearer access token string

Returns multiple values:
  1. Character ID (integer)
  2. Character name (string)

Signals EVE-SSO-ERROR if verification fails."
  (handler-case
      (let* ((response (dex:get *eve-sso-verify-url*
                                :headers `(("Authorization"
                                            . ,(format nil "Bearer ~A" access-token))
                                           ("User-Agent" . ,eve-gate.core:*user-agent*))
                                :force-string t))
             (data (com.inuoe.jzon:parse response)))
        (when (hash-table-p data)
          (values
           (gethash "CharacterID" data)
           (gethash "CharacterName" data))))
    (error (e)
      (log-warn "Token verification failed: ~A" e)
      (error 'eve-sso-error
             :message (format nil "Token verification failed: ~A" e)
             :sso-error-type :verification-failed))))

;;; ---------------------------------------------------------------------------
;;; Internal helpers
;;; ---------------------------------------------------------------------------

(defun %base64url-decode-to-string (segment)
  "Decode a base64url-encoded JWT segment to a UTF-8 string.

SEGMENT: Base64url string (uses -/_ and may lack padding).

Returns: Decoded string, or NIL on decode failure."
  (handler-case
      (let* ((std (map 'string
                       (lambda (c)
                         (case c (#\- #\+) (#\_ #\/) (t c)))
                       segment))
             (pad-needed (mod (- 4 (mod (length std) 4)) 4))
             (padded (if (zerop pad-needed)
                         std
                         (concatenate 'string std
                                      (make-string pad-needed :initial-element #\=))))
             (bytes (cl-base64:base64-string-to-usb8-array padded)))
        (babel:octets-to-string bytes :encoding :utf-8))
    (error () nil)))

(defun extract-jwt-scopes (access-token)
  "Extract the list of granted scope strings from the JWT `scp` claim.

EVE SSO access tokens are RS256-signed JWTs whose payload includes
an `scp` claim with the granted scopes. For a single scope the
payload encodes `scp` as a string; for multiple scopes it's an
array.

ACCESS-TOKEN: A three-segment JWT string (`header.payload.signature`).

Returns: A list of scope strings, or NIL if the token cannot be
decoded or has no `scp` claim. This is a best-effort fallback used
when the OAuth library does not surface scopes separately — it does
not verify the signature, so callers must have already confirmed
token authenticity via EVE SSO (e.g. VERIFY-ACCESS-TOKEN)."
  (when (stringp access-token)
    (let ((parts (cl-ppcre:split "\\." access-token)))
      (when (= (length parts) 3)
        (let ((json (%base64url-decode-to-string (second parts))))
          (when json
            (handler-case
                (let* ((parsed (com.inuoe.jzon:parse json))
                       (scp (and (hash-table-p parsed) (gethash "scp" parsed))))
                  (cond
                    ((null scp) nil)
                    ((stringp scp) (parse-scope-string scp))
                    ((listp scp) (copy-list scp))
                    ((vectorp scp) (coerce scp 'list))
                    (t nil)))
              (error () nil))))))))

(defun compute-expires-in (ciao-oauth obtained-at)
  "Compute remaining seconds until token expiration.

CIAO-OAUTH: A CIAO oauth2 object
OBTAINED-AT: Universal time when the token was obtained

Returns: Seconds until expiration (integer), or 1200 as default
(EVE SSO tokens typically expire after 20 minutes = 1200 seconds)."
  (let ((expiration (slot-value ciao-oauth 'ciao::expiration)))
    (if (and (numberp expiration) (not (eq expiration 'ciao::inf+)))
        (max 0 (- expiration obtained-at))
        1200)))

;;; ---------------------------------------------------------------------------
;;; Authentication middleware
;;; ---------------------------------------------------------------------------

(defun make-auth-middleware (token-manager-fn)
  "Create middleware that injects Bearer authentication headers.

TOKEN-MANAGER-FN: A function of zero arguments that returns the current
                  valid access token string, or NIL if not authenticated.
                  This function should handle automatic token refresh.
                  (Typically bound to the token-manager's get-valid-token.)

The middleware runs at priority 15 (after standard headers, before logging)
so that authentication headers are established early in the pipeline.

Returns: A middleware struct for the HTTP client pipeline.

Example:
  (make-auth-middleware
   (lambda () (get-valid-access-token my-token-manager)))"
  (eve-gate.core:make-middleware
   :name :authentication
   :priority 15
   :request-fn
   (lambda (ctx)
     (let ((token (funcall token-manager-fn)))
       (when token
         (let ((headers (getf ctx :headers)))
           (setf (getf ctx :headers)
                 (cons (cons "Authorization"
                             (format nil "Bearer ~A" token))
                       (remove "Authorization" headers
                               :key #'car :test #'string-equal))))))
     ctx)))

(defun make-scope-checking-middleware (token-manager-fn endpoint-scope-fn)
  "Create middleware that validates required scopes before making requests.

TOKEN-MANAGER-FN: Function returning current granted scopes (list of strings)
ENDPOINT-SCOPE-FN: Function (endpoint-path) -> required scope string or NIL.
                   Returns the scope required for a given ESI endpoint.

Signals EVE-SSO-INSUFFICIENT-SCOPES if the token lacks a required scope.

Returns: A middleware struct.

Example:
  (make-scope-checking-middleware
   (lambda () (token-manager-scopes my-manager))
   (lambda (path) (endpoint-required-scope path)))"
  (eve-gate.core:make-middleware
   :name :scope-check
   :priority 12
   :request-fn
   (lambda (ctx)
     (let* ((path (getf ctx :path))
            (required-scope (funcall endpoint-scope-fn path)))
       (when required-scope
         (let ((granted (funcall token-manager-fn)))
           (unless (scope-required-p required-scope granted)
             (error 'eve-sso-insufficient-scopes
                    :required-scopes (list required-scope)
                    :granted-scopes granted
                    :endpoint path)))))
     ctx)))

;;; ---------------------------------------------------------------------------
;;; Browser-based authentication flow (convenience)
;;; ---------------------------------------------------------------------------

(defun authenticate-via-browser (oauth-client &key scopes (port *default-callback-port*))
  "Perform the complete browser-based OAuth authentication flow.

Opens the user's browser to EVE SSO, starts a local callback server
to receive the authorization code, and exchanges it for tokens.
This is the simplest way to authenticate interactively.

OAUTH-CLIENT: An oauth-client struct
SCOPES: Override the client's default scopes (optional)
PORT: Local port for the callback server (default: *default-callback-port*)

Returns: A token-info plist (same format as EXCHANGE-CODE-FOR-TOKEN).

Note: This blocks the current thread until the user completes authentication
in their browser.

Example:
  (let* ((client (make-oauth-client :client-id \"...\" :client-secret \"...\"))
         (token-info (authenticate-via-browser client)))
    (format t \"Authenticated as ~A~%\" (getf token-info :character-name)))"
  (let* ((effective-scopes (or scopes (oauth-client-scopes oauth-client)))
         (redirect-uri (format nil "http://localhost:~D/oauth" port)))
    (handler-case
        (let ((ciao-oauth (ciao:oauth2/request-auth-code/browser
                           (oauth-client-auth-server oauth-client)
                           (oauth-client-ciao-client oauth-client)
                           :scopes effective-scopes
                           :port port)))
          ;; Store the CIAO object on our client
          (setf (oauth-client-ciao-oauth oauth-client) ciao-oauth)
          ;; Build token info from the result
          (let* ((now (get-universal-time))
                 (access-token (ciao:get-access-token ciao-oauth :re-acquire? nil))
                 (refresh-token (ciao:get-refresh-token ciao-oauth))
                 (ciao-scopes (slot-value ciao-oauth 'ciao::scopes))
                 (scopes (or (if (listp ciao-scopes) ciao-scopes
                                 (when ciao-scopes (parse-scope-string ciao-scopes)))
                             ;; Fallback: EVE SSO doesn't always return scopes
                             ;; via the OAuth library — extract from the JWT.
                             (extract-jwt-scopes access-token))))
            (multiple-value-bind (character-id character-name)
                (verify-access-token access-token)
              (let ((token-info
                      (list :access-token access-token
                            :refresh-token refresh-token
                            :expires-in (compute-expires-in ciao-oauth now)
                            :token-type "Bearer"
                            :scopes scopes
                            :character-id character-id
                            :character-name character-name
                            :obtained-at now)))
                (log-info "EVE SSO: Browser auth complete for ~A (ID: ~A)"
                          character-name character-id)
                token-info))))
      (error (e)
        (log-error "Browser authentication failed: ~A" e)
        (error 'eve-sso-error
               :message (format nil "Browser authentication failed: ~A" e)
               :sso-error-type :browser-auth-failed)))))
