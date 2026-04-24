;;;; token-manager.lisp - Token lifecycle management for eve-gate
;;;;
;;;; Manages the complete lifecycle of OAuth 2.0 tokens for EVE SSO:
;;;;
;;;;   - Token storage (in-memory state with filesystem persistence)
;;;;   - Automatic refresh before expiration (proactive, not reactive)
;;;;   - Authentication state queries (expired? authenticated? scopes?)
;;;;   - Token persistence across application sessions (file-based)
;;;;   - Thread-safe access to token state
;;;;   - Integration with the OAuth client for refresh operations
;;;;
;;;; The token-manager is the central authority for token state in
;;;; eve-gate. All other components obtain access tokens through the
;;;; token manager rather than directly from the OAuth client. This
;;;; provides a single point of control for refresh logic, scope
;;;; validation, and persistence.
;;;;
;;;; Token persistence uses a simple s-expression file format for
;;;; portability and human readability. The token file contains a
;;;; plist with the refresh token, granted scopes, character info,
;;;; and metadata. Access tokens are NOT persisted (they expire in
;;;; 20 minutes and should be refreshed from the refresh token).
;;;;
;;;; Design:
;;;;   - Token-manager struct holds mutable state (via setf on slots)
;;;;   - Public interface is functional: get-valid-access-token returns
;;;;     a token string or signals a condition
;;;;   - Refresh is proactive: tokens are refreshed when they have
;;;;     less than *refresh-threshold* seconds remaining
;;;;   - Persistence is explicit: call SAVE-TOKEN-STATE / LOAD-TOKEN-STATE

(in-package #:eve-gate.auth)

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(defparameter *refresh-threshold* 300
  "Seconds before expiration at which to proactively refresh the token.
Default is 300 seconds (5 minutes). EVE SSO tokens expire after 1200
seconds (20 minutes), so this triggers refresh at the 15-minute mark.")

(defparameter *token-storage-directory*
  (merge-pathnames #P".eve-gate/tokens/"
                   (user-homedir-pathname))
  "Default directory for persisting token files.
Each character's token is stored in a separate file named by character ID.")

(defparameter *token-file-permissions* #o600
  "Unix file permissions for token files.
Restricted to owner-only read/write since tokens are sensitive.")

;;; ---------------------------------------------------------------------------
;;; Token info structure
;;; ---------------------------------------------------------------------------

(defstruct (token-info (:constructor %make-token-info))
  "Holds the current state of an OAuth 2.0 token pair.

Slots:
  ACCESS-TOKEN: The current bearer token for API requests
  REFRESH-TOKEN: Token used to obtain new access tokens
  EXPIRES-AT: Universal time when the access token expires
  TOKEN-TYPE: Always \"Bearer\" for EVE SSO
  SCOPES: List of granted scope strings
  CHARACTER-ID: EVE character ID associated with this token
  CHARACTER-NAME: EVE character name
  OBTAINED-AT: Universal time when the token was last obtained/refreshed"
  (access-token nil :type (or null string))
  (refresh-token nil :type (or null string))
  (expires-at 0 :type integer)
  (token-type "Bearer" :type string)
  (scopes nil :type list)
  (character-id nil)
  (character-name nil :type (or null string))
  (obtained-at 0 :type integer))

(defun make-token-info-from-plist (plist)
  "Create a TOKEN-INFO struct from a token-info plist (as returned by
EXCHANGE-CODE-FOR-TOKEN or REFRESH-ACCESS-TOKEN).

PLIST: A plist with :ACCESS-TOKEN, :REFRESH-TOKEN, :EXPIRES-IN, etc.

Returns: A token-info struct."
  (let ((now (or (getf plist :obtained-at) (get-universal-time)))
        (expires-in (or (getf plist :expires-in) 1200)))
    (%make-token-info
     :access-token (getf plist :access-token)
     :refresh-token (getf plist :refresh-token)
     :expires-at (+ now expires-in)
     :token-type (or (getf plist :token-type) "Bearer")
     :scopes (getf plist :scopes)
     :character-id (getf plist :character-id)
     :character-name (getf plist :character-name)
     :obtained-at now)))

;;; ---------------------------------------------------------------------------
;;; Token state predicates (pure)
;;; ---------------------------------------------------------------------------

(defun token-expired-p (token-info &optional (now (get-universal-time)))
  "Return T if the access token has expired.

TOKEN-INFO: A token-info struct
NOW: Current time as universal time (default: current time)

Returns: T if expired, NIL if still valid."
  (and token-info
       (>= now (token-info-expires-at token-info))))

(defun token-needs-refresh-p (token-info &optional (now (get-universal-time)))
  "Return T if the access token should be proactively refreshed.
Triggers when the token has less than *REFRESH-THRESHOLD* seconds remaining.

TOKEN-INFO: A token-info struct
NOW: Current time as universal time

Returns: T if the token should be refreshed."
  (and token-info
       (>= now (- (token-info-expires-at token-info) *refresh-threshold*))))

(defun token-valid-p (token-info &optional (now (get-universal-time)))
  "Return T if the token exists and has not expired.

TOKEN-INFO: A token-info struct
NOW: Current time as universal time

Returns: T if token is present and not expired."
  (and token-info
       (token-info-access-token token-info)
       (not (token-expired-p token-info now))))

(defun token-time-remaining (token-info &optional (now (get-universal-time)))
  "Return the number of seconds until token expiration.

TOKEN-INFO: A token-info struct
NOW: Current time as universal time

Returns: Seconds remaining (may be negative if already expired)."
  (if token-info
      (- (token-info-expires-at token-info) now)
      0))

;;; ---------------------------------------------------------------------------
;;; Token manager structure
;;; ---------------------------------------------------------------------------

(defstruct (token-manager (:constructor %make-token-manager))
  "Manages the lifecycle of OAuth 2.0 tokens for a single EVE character.

Slots:
  OAUTH-CLIENT: The oauth-client used for token refresh operations
  TOKEN: Current token-info struct (or NIL if not authenticated)
  STORAGE-PATH: Filesystem path for token persistence (or NIL to disable)
  AUTO-REFRESH-P: Whether to automatically refresh tokens before expiration
  LOCK: Mutex for thread-safe token access"
  (oauth-client nil :type (or null oauth-client))
  (token nil :type (or null token-info))
  (storage-path nil :type (or null pathname))
  (auto-refresh-p t :type boolean)
  (lock (bt:make-lock "token-manager") :read-only t))

(defun make-token-manager (oauth-client &key (storage-path nil storage-path-p)
                                             (auto-refresh t)
                                             (character-id nil))
  "Create a token manager for managing OAuth token lifecycle.

OAUTH-CLIENT: An oauth-client struct for token refresh operations
STORAGE-PATH: Path for token persistence file. When NIL, persistence is disabled.
              When not supplied, uses *TOKEN-STORAGE-DIRECTORY*/<character-id>.sexp
              if CHARACTER-ID is provided.
AUTO-REFRESH: Whether to proactively refresh tokens (default: T)
CHARACTER-ID: Character ID for deriving the default storage path

Returns: A token-manager struct.

Example:
  (make-token-manager oauth-client)
  (make-token-manager oauth-client :storage-path #P\"/path/to/tokens/12345.sexp\")
  (make-token-manager oauth-client :character-id 12345)"
  (let ((effective-storage-path
          (cond
            (storage-path-p storage-path)
            (character-id
             (merge-pathnames
              (make-pathname :name (format nil "~A" character-id) :type "sexp")
              *token-storage-directory*))
            (t nil))))
    (%make-token-manager
     :oauth-client oauth-client
     :token nil
     :storage-path effective-storage-path
     :auto-refresh-p auto-refresh)))

;;; ---------------------------------------------------------------------------
;;; Token access and refresh
;;; ---------------------------------------------------------------------------

(defun get-valid-access-token (manager)
  "Return a valid access token string, refreshing if necessary.

This is the primary interface for obtaining an access token. It:
  1. Checks if the current token is valid
  2. If the token needs refresh (within threshold), refreshes proactively
  3. If the token is expired but a refresh token exists, attempts refresh
  4. Returns the (possibly refreshed) access token string

MANAGER: A token-manager struct

Returns: An access token string.

Signals:
  EVE-SSO-TOKEN-EXPIRED: If no valid token and refresh is not possible
  EVE-SSO-TOKEN-REFRESH-FAILED: If refresh attempt fails

Example:
  (get-valid-access-token manager) => \"eyJhbGciOi...\""
  (bt:with-lock-held ((token-manager-lock manager))
    (let ((token (token-manager-token manager)))
      (cond
        ;; No token at all
        ((null token)
         (error 'eve-sso-token-expired
                :sso-error-description "No token available. Authenticate first."))
        ;; Token is valid and doesn't need refresh
        ((and (token-valid-p token) (not (token-needs-refresh-p token)))
         (token-info-access-token token))
        ;; Token needs refresh (proactive or expired)
        ((and (token-manager-auto-refresh-p manager)
              (token-info-refresh-token token))
         (log-info "Token ~A, refreshing..."
                   (if (token-expired-p token) "expired" "near expiration"))
         (handler-case
             (let ((refreshed (refresh-token-internal manager)))
               (token-info-access-token refreshed))
           (error (e)
             ;; If refresh fails but token hasn't actually expired yet, use it
             (if (token-valid-p token)
                 (progn
                   (log-warn "Proactive token refresh failed: ~A. Using existing token." e)
                   (token-info-access-token token))
                 ;; Token is actually expired and refresh failed
                 (error 'eve-sso-token-refresh-failed
                        :original-error e
                        :sso-error-description
                        (format nil "Token expired and refresh failed: ~A" e))))))
        ;; Token expired, no refresh possible
        ((token-expired-p token)
         (error 'eve-sso-token-expired
                :sso-error-description
                (format nil "Token expired ~D seconds ago. No refresh token available."
                        (- (get-universal-time) (token-info-expires-at token)))))
        ;; Token is valid (fallback)
        (t (token-info-access-token token))))))

(defun refresh-token-internal (manager)
  "Internal: Perform token refresh and update manager state.
Caller must hold the manager lock.

MANAGER: A token-manager struct

Returns: The new token-info struct."
  (let* ((current-token (token-manager-token manager))
         (refresh-token (token-info-refresh-token current-token))
         (result-plist (refresh-access-token
                        (token-manager-oauth-client manager)
                        refresh-token))
         (new-token (make-token-info-from-plist result-plist)))
    ;; Preserve character info if not returned by refresh
    (unless (token-info-character-id new-token)
      (setf (token-info-character-id new-token)
            (token-info-character-id current-token)))
    (unless (token-info-character-name new-token)
      (setf (token-info-character-name new-token)
            (token-info-character-name current-token)))
    ;; Preserve scopes if refresh didn't surface them and we had them before
    (unless (token-info-scopes new-token)
      (setf (token-info-scopes new-token)
            (token-info-scopes current-token)))
    ;; Update manager state
    (setf (token-manager-token manager) new-token)
    ;; Persist if enabled
    (when (token-manager-storage-path manager)
      (handler-case
          (save-token-state manager)
        (error (e)
          (log-warn "Failed to persist token after refresh: ~A" e))))
    new-token))

;;; ---------------------------------------------------------------------------
;;; Token state management  
;;; ---------------------------------------------------------------------------

(defun store-token (manager token-plist)
  "Store a token-info plist in the manager and optionally persist it.

This is called after initial authentication (EXCHANGE-CODE-FOR-TOKEN)
to install the token in the manager.

MANAGER: A token-manager struct
TOKEN-PLIST: A plist from exchange-code-for-token or refresh-access-token

Returns: The token-info struct.

Example:
  (let ((token-info (exchange-code-for-token client code)))
    (store-token manager token-info))"
  (bt:with-lock-held ((token-manager-lock manager))
    (let ((token (make-token-info-from-plist token-plist)))
      (setf (token-manager-token manager) token)
      ;; Update storage path based on character ID if not already set
      (when (and (null (token-manager-storage-path manager))
                 (token-info-character-id token))
        (setf (token-manager-storage-path manager)
              (merge-pathnames
               (make-pathname :name (format nil "~A" (token-info-character-id token))
                              :type "sexp")
               *token-storage-directory*)))
      ;; Persist
      (when (token-manager-storage-path manager)
        (handler-case
            (save-token-state manager)
          (error (e)
            (log-warn "Failed to persist token: ~A" e))))
      token)))

(defun load-token (manager)
  "Load persisted token state from the filesystem.
Restores the refresh token and character info, then attempts
to refresh the access token.

MANAGER: A token-manager struct with a STORAGE-PATH set

Returns: T if token was loaded and refreshed successfully, NIL otherwise.

Example:
  (when (load-token manager)
    (format t \"Restored session for ~A~%\" 
            (token-info-character-name (token-manager-token manager))))"
  (bt:with-lock-held ((token-manager-lock manager))
    (let ((path (token-manager-storage-path manager)))
      (when (and path (probe-file path))
        (handler-case
            (let ((state (load-token-file path)))
              (when state
                ;; Create a token-info with the persisted refresh token
                ;; Access token will be stale, so set expiration in the past
                (let ((token (%make-token-info
                              :access-token nil
                              :refresh-token (getf state :refresh-token)
                              :expires-at 0  ; Force refresh
                              :scopes (getf state :scopes)
                              :character-id (getf state :character-id)
                              :character-name (getf state :character-name)
                              :obtained-at (or (getf state :saved-at) 0))))
                  (setf (token-manager-token manager) token)
                  (log-info "Loaded persisted token for ~A (ID: ~A)"
                            (token-info-character-name token)
                            (token-info-character-id token))
                  ;; Attempt to refresh the access token
                  (handler-case
                      (progn
                        (refresh-token-internal manager)
                        (log-info "Token refreshed successfully after restore")
                        t)
                    (error (e)
                      (log-warn "Failed to refresh token after restore: ~A" e)
                      ;; Token is loaded but not refreshed - caller can retry
                      nil)))))
          (error (e)
            (log-error "Failed to load token from ~A: ~A" path e)
            nil))))))

;;; ---------------------------------------------------------------------------
;;; Token state queries
;;; ---------------------------------------------------------------------------

(defun token-manager-authenticated-p (manager)
  "Return T if the manager has a non-expired token.

MANAGER: A token-manager struct"
  (let ((token (token-manager-token manager)))
    (and token (token-valid-p token))))

(defun token-manager-character-id (manager)
  "Return the character ID associated with the current token, or NIL.

MANAGER: A token-manager struct"
  (when-let ((token (token-manager-token manager)))
    (token-info-character-id token)))

(defun token-manager-character-name (manager)
  "Return the character name associated with the current token, or NIL.

MANAGER: A token-manager struct"
  (when-let ((token (token-manager-token manager)))
    (token-info-character-name token)))

(defun token-manager-scopes (manager)
  "Return the list of granted scope strings for the current token, or NIL.

MANAGER: A token-manager struct"
  (when-let ((token (token-manager-token manager)))
    (token-info-scopes token)))

(defun token-manager-expires-at (manager)
  "Return the expiration time (universal time) of the current access token.

MANAGER: A token-manager struct

Returns: Universal time integer, or 0 if no token."
  (if-let ((token (token-manager-token manager)))
    (token-info-expires-at token)
    0))

(defun token-manager-status (manager)
  "Return a human-readable status summary of the token manager.
Useful for REPL inspection and monitoring.

MANAGER: A token-manager struct

Returns: A plist with status information."
  (let ((token (token-manager-token manager)))
    (list :authenticated (and token (token-valid-p token) t)
          :character-id (when token (token-info-character-id token))
          :character-name (when token (token-info-character-name token))
          :scopes-count (if token (length (token-info-scopes token)) 0)
          :expires-in (if token (token-time-remaining token) 0)
          :needs-refresh (and token (token-needs-refresh-p token) t)
          :has-refresh-token (and token (token-info-refresh-token token) t)
          :storage-path (token-manager-storage-path manager)
          :auto-refresh (token-manager-auto-refresh-p manager))))

;;; ---------------------------------------------------------------------------
;;; Token revocation
;;; ---------------------------------------------------------------------------

(defun revoke-token (manager)
  "Revoke the current token and clear the manager state.

Attempts to revoke the token at the EVE SSO revocation endpoint,
then clears all local token state regardless of whether revocation
succeeded remotely.

MANAGER: A token-manager struct

Returns: T if revocation was successful, NIL if it failed (but state
is cleared either way)."
  (bt:with-lock-held ((token-manager-lock manager))
    (let* ((token (token-manager-token manager))
           (revoked nil))
      ;; Attempt remote revocation
      (when (and token (token-info-refresh-token token))
        (handler-case
            (progn
              (dex:post *eve-sso-revoke-url*
                        :headers `(("Content-Type" . "application/x-www-form-urlencoded")
                                   ("User-Agent" . ,eve-gate.core:*user-agent*))
                        :content `(("token" . ,(token-info-refresh-token token))
                                   ("token_type_hint" . "refresh_token")
                                   ("client_id" . ,(oauth-client-client-id
                                                    (token-manager-oauth-client manager)))
                                   ("client_secret" . ,(oauth-client-client-secret
                                                        (token-manager-oauth-client manager)))))
              (setf revoked t)
              (log-info "Token revoked for ~A (ID: ~A)"
                        (token-info-character-name token)
                        (token-info-character-id token)))
          (error (e)
            (log-warn "Remote token revocation failed: ~A" e))))
      ;; Clear local state regardless
      (setf (token-manager-token manager) nil)
      ;; Remove persisted token file
      (when (token-manager-storage-path manager)
        (handler-case
            (when (probe-file (token-manager-storage-path manager))
              (delete-file (token-manager-storage-path manager))
              (log-debug "Removed persisted token file: ~A"
                         (token-manager-storage-path manager)))
          (error (e)
            (log-warn "Failed to remove token file: ~A" e))))
      revoked)))

;;; ---------------------------------------------------------------------------
;;; Filesystem persistence
;;; ---------------------------------------------------------------------------

(defun save-token-state (manager)
  "Persist the current token state to the filesystem.
Only the refresh token, scopes, and character info are saved.
Access tokens are NOT persisted (they expire quickly).

MANAGER: A token-manager struct

Returns: The pathname of the saved file, or NIL.

The file format is a readable s-expression plist."
  (let ((path (token-manager-storage-path manager))
        (token (token-manager-token manager)))
    (when (and path token (token-info-refresh-token token))
      (ensure-token-directory path)
      (let ((state (list :refresh-token (token-info-refresh-token token)
                         :scopes (token-info-scopes token)
                         :character-id (token-info-character-id token)
                         :character-name (token-info-character-name token)
                         :saved-at (get-universal-time)
                         :format-version 1)))
        (with-open-file (stream path
                                :direction :output
                                :if-exists :supersede
                                :if-does-not-exist :create)
          (write-string ";;; eve-gate token state - DO NOT EDIT" stream)
          (terpri stream)
          (write-string ";;; This file contains sensitive OAuth 2.0 credentials" stream)
          (terpri stream)
          (let ((*print-readably* t)
                (*print-pretty* t)
                (*print-right-margin* 80))
            (prin1 state stream))
          (terpri stream))
        ;; Set restrictive permissions on Unix systems
        #+sbcl
        (handler-case
            (sb-posix:chmod (namestring path) *token-file-permissions*)
          (error () nil))
        (log-debug "Token state saved to ~A" path)
        path))))

(defun load-token-file (path)
  "Load a persisted token state from a file.

PATH: Pathname to the token state file

Returns: The state plist, or NIL if the file cannot be read.

The function validates the format version and basic structure."
  (handler-case
      (with-open-file (stream path :direction :input)
        (let ((state (read stream nil nil)))
          (when (and (listp state)
                     (getf state :refresh-token)
                     (eql (getf state :format-version) 1))
            state)))
    (error (e)
      (log-warn "Error reading token file ~A: ~A" path e)
      nil)))

(defun ensure-token-directory (path)
  "Ensure the parent directory of PATH exists.

PATH: A pathname whose directory may need to be created."
  (let ((dir (make-pathname :directory (pathname-directory path)
                            :defaults path)))
    (ensure-directories-exist dir)))

;;; ---------------------------------------------------------------------------
;;; Token discovery (find persisted tokens)
;;; ---------------------------------------------------------------------------

(defun list-persisted-tokens (&optional (directory *token-storage-directory*))
  "List all persisted token files in DIRECTORY.
Returns a list of plists with :PATH, :CHARACTER-ID, :CHARACTER-NAME, :SAVED-AT.

DIRECTORY: Path to search for .sexp token files (default: *token-storage-directory*)

Returns: List of summary plists, sorted by most recently saved first.

Example:
  (list-persisted-tokens)
  => ((:PATH #P\"/home/user/.eve-gate/tokens/12345.sexp\"
      :CHARACTER-ID 12345
      :CHARACTER-NAME \"Pilot Name\"
      :SAVED-AT 3919876543))"
  (when (and directory (probe-file directory))
    (let ((results nil))
      (dolist (file (directory (merge-pathnames
                                (make-pathname :name :wild :type "sexp")
                                directory)))
        (handler-case
            (let ((state (load-token-file file)))
              (when state
                (push (list :path file
                            :character-id (getf state :character-id)
                            :character-name (getf state :character-name)
                            :saved-at (getf state :saved-at))
                      results)))
          (error () nil)))
      (sort results #'> :key (lambda (r) (or (getf r :saved-at) 0))))))

;;; ---------------------------------------------------------------------------
;;; Convenience: combined auth + token management
;;; ---------------------------------------------------------------------------

(defun authenticate-and-store (oauth-client manager authorization-code)
  "Exchange an authorization code for tokens and install them in the manager.

This is the typical post-callback operation: the user has authenticated
in their browser, and we now have the authorization code.

OAUTH-CLIENT: An oauth-client struct
MANAGER: A token-manager struct
AUTHORIZATION-CODE: The code from the EVE SSO callback

Returns: The token-manager (for chaining).

Example:
  (authenticate-and-store oauth-client manager code)"
  (let ((token-plist (exchange-code-for-token oauth-client authorization-code)))
    (store-token manager token-plist)
    manager))

(defun restore-or-authenticate (oauth-client manager &key (browser-auth nil))
  "Try to restore a persisted token, falling back to authentication if needed.

First attempts to load and refresh a persisted token. If that fails
and BROWSER-AUTH is T, initiates browser-based authentication.

OAUTH-CLIENT: An oauth-client struct
MANAGER: A token-manager struct (should have STORAGE-PATH set)
BROWSER-AUTH: Whether to fall back to browser auth if restore fails

Returns: T if authentication was successful, NIL otherwise.

Example:
  (restore-or-authenticate client manager :browser-auth t)"
  (or (load-token manager)
      (when browser-auth
        (handler-case
            (let ((token-plist (authenticate-via-browser oauth-client)))
              (store-token manager token-plist)
              t)
          (error (e)
            (log-error "Authentication failed: ~A" e)
            nil)))))
