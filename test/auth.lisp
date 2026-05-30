;;;; test/auth.lisp - Authentication system tests for eve-gate
;;;;
;;;; Tests for OAuth 2.0 client, token management, and scope handling

(uiop:define-package #:eve-gate/test/auth
  (:use #:cl)
  (:import-from #:eve-gate.auth
                ;; OAuth client
                #:make-oauth-client
                #:oauth-client-client-id
                #:oauth-client-scopes
                #:oauth-client-redirect-uri
                #:get-authorization-url
                ;; Token manager / refresh
                #:make-token-manager
                #:get-valid-access-token
                ;; Scopes
                #:valid-scope-p
                #:validate-scopes
                #:scope-required-p
                #:sufficient-scopes-p
                #:missing-scopes
                #:merge-scopes
                #:subtract-scopes
                #:parse-scope-string
                #:format-scopes-for-oauth
                #:scopes-by-category
                ;; Token info
                #:token-info
                #:token-info-access-token
                #:token-info-expires-at
                #:token-expired-p
                #:token-needs-refresh-p
                ;; Conditions
                #:eve-sso-error
                #:eve-sso-insufficient-scopes
                #:eve-sso-token-refresh-failed
                #:eve-sso-error-type)
  (:local-nicknames (#:t #:parachute)))

(in-package #:eve-gate/test/auth)

;;; Scope Validation Tests

(t:define-test valid-scope-p-function
  "Test scope validity checking"
  (t:true (valid-scope-p "esi-skills.read_skills.v1"))
  (t:true (valid-scope-p "esi-wallet.read_character_wallet.v1"))
  (t:true (valid-scope-p "esi-location.read_location.v1"))
  (t:false (valid-scope-p "invalid-scope"))
  (t:false (valid-scope-p ""))
  (t:false (valid-scope-p nil)))

(t:define-test validate-scopes-function
  "Test batch scope validation"
  ;; Valid scopes should pass
  (t:finish (validate-scopes '("esi-skills.read_skills.v1")))
  
  ;; Invalid scopes should signal error
  (t:fail (validate-scopes '("not-a-real-scope")) 'error))

(t:define-test scope-required-p-function
  "Test checking if a scope is in a granted list"
  (let ((granted '("esi-skills.read_skills.v1" 
                   "esi-wallet.read_character_wallet.v1")))
    (t:true (scope-required-p "esi-skills.read_skills.v1" granted))
    (t:true (scope-required-p "esi-wallet.read_character_wallet.v1" granted))
    (t:false (scope-required-p "esi-location.read_location.v1" granted))))

(t:define-test sufficient-scopes-p-function
  "Test checking if granted scopes cover required scopes"
  (let ((granted '("esi-skills.read_skills.v1" 
                   "esi-wallet.read_character_wallet.v1"
                   "esi-location.read_location.v1")))
    (t:true (sufficient-scopes-p '("esi-skills.read_skills.v1") granted))
    (t:true (sufficient-scopes-p '("esi-skills.read_skills.v1" 
                                   "esi-wallet.read_character_wallet.v1") 
                                 granted))
    (t:false (sufficient-scopes-p '("esi-skills.read_skills.v1"
                                    "esi-mail.read_mail.v1")
                                  granted))))

(t:define-test missing-scopes-function
  "Test identifying missing scopes"
  (let ((granted '("esi-skills.read_skills.v1"))
        (required '("esi-skills.read_skills.v1" 
                    "esi-wallet.read_character_wallet.v1")))
    (let ((missing (missing-scopes required granted)))
      (t:is = 1 (length missing))
      (t:true (member "esi-wallet.read_character_wallet.v1" missing 
                      :test #'string=)))))

;;; Scope Operations Tests

(t:define-test merge-scopes-function
  "Test merging scope lists"
  (let ((list1 '("esi-skills.read_skills.v1"))
        (list2 '("esi-wallet.read_character_wallet.v1"))
        (list3 '("esi-skills.read_skills.v1")))  ; Duplicate
    (let ((merged (merge-scopes list1 list2 list3)))
      (t:is = 2 (length merged))
      (t:true (member "esi-skills.read_skills.v1" merged :test #'string=))
      (t:true (member "esi-wallet.read_character_wallet.v1" merged :test #'string=)))))

(t:define-test subtract-scopes-function
  "Test removing scopes from a list"
  (let ((all '("esi-skills.read_skills.v1" 
               "esi-wallet.read_character_wallet.v1"
               "esi-location.read_location.v1"))
        (remove '("esi-wallet.read_character_wallet.v1")))
    (let ((result (subtract-scopes all remove)))
      (t:is = 2 (length result))
      (t:false (member "esi-wallet.read_character_wallet.v1" result 
                       :test #'string=)))))

(t:define-test parse-scope-string-function
  "Test parsing space-separated scope strings"
  (let ((scope-string "esi-skills.read_skills.v1 esi-wallet.read_character_wallet.v1"))
    (let ((parsed (parse-scope-string scope-string)))
      (t:is = 2 (length parsed))
      (t:true (member "esi-skills.read_skills.v1" parsed :test #'string=))
      (t:true (member "esi-wallet.read_character_wallet.v1" parsed :test #'string=)))))

(t:define-test format-scopes-for-oauth-function
  "Test formatting scopes for OAuth URL"
  (let ((scopes '("esi-skills.read_skills.v1" "esi-wallet.read_character_wallet.v1")))
    (let ((formatted (format-scopes-for-oauth scopes)))
      (t:true (stringp formatted))
      (t:true (search "esi-skills.read_skills.v1" formatted))
      (t:true (search "esi-wallet.read_character_wallet.v1" formatted)))))

;;; Scope Category Tests

(t:define-test scopes-by-category-function
  "Test retrieving scopes by category"
  (let ((skill-scopes (scopes-by-category :skills)))
    (t:true (listp skill-scopes))
    ;; Should contain at least the read_skills scope
    (t:true (or (null skill-scopes)
                (some (lambda (s) (search "skill" s)) skill-scopes)))))

;;; OAuth Client Tests

(t:define-test oauth-client-creation
  "Test OAuth client creation with required parameters"
  (let ((client (make-oauth-client 
                 :client-id "test-client-id"
                 :client-secret "test-client-secret"
                 :scopes '("esi-skills.read_skills.v1"))))
    (t:true client)
    (t:is string= "test-client-id" (oauth-client-client-id client))
    (t:is = 1 (length (oauth-client-scopes client)))))

(t:define-test oauth-client-requires-credentials
  "Test that OAuth client requires client-id and secret"
  (t:fail (make-oauth-client :client-id nil :client-secret "secret") 'error)
  (t:fail (make-oauth-client :client-id "id" :client-secret nil) 'error)
  (t:fail (make-oauth-client :client-id "" :client-secret "secret") 'error))

(t:define-test oauth-client-validates-scopes
  "Test that OAuth client validates scope strings"
  ;; Valid scopes should work
  (t:finish (make-oauth-client 
             :client-id "test-id"
             :client-secret "test-secret"
             :scopes '("esi-skills.read_skills.v1")))
  
  ;; Invalid scopes should fail
  (t:fail (make-oauth-client 
           :client-id "test-id"
           :client-secret "test-secret"
           :scopes '("invalid-scope-string"))
          'error))

(t:define-test get-authorization-url-generation
  "Test authorization URL generation"
  (let* ((client (make-oauth-client 
                  :client-id "test-client-id"
                  :client-secret "test-client-secret"
                  :scopes '("esi-skills.read_skills.v1")))
         (auth-url (get-authorization-url client)))
    (t:true (stringp auth-url))
    (t:true (search "login.eveonline.com" auth-url))
    (t:true (search "authorize" auth-url))
    (t:true (search "client_id" auth-url))
    (t:true (search "test-client-id" auth-url))))

(t:define-test authorization-url-with-state
  "Test authorization URL includes state parameter"
  (let* ((client (make-oauth-client 
                  :client-id "test-client-id"
                  :client-secret "test-client-secret"))
         (auth-url (get-authorization-url client :state "csrf-token-123")))
    (t:true (search "state" auth-url))
    (t:true (search "csrf-token-123" auth-url))))

;;; Token State Tests
;;; Note: token-expired-p and token-needs-refresh-p expect token-info structs

(t:define-test token-expired-p-with-nil
  "Test token-expired-p returns nil for nil input"
  (t:false (token-expired-p nil)))

(t:define-test token-needs-refresh-p-with-nil
  "Test token-needs-refresh-p returns nil for nil input"
  (t:false (token-needs-refresh-p nil)))

;;; Condition Tests

(t:define-test eve-sso-insufficient-scopes-condition
  "Test insufficient scopes condition"
  (let ((condition (make-condition 'eve-sso-insufficient-scopes
                                   :required-scopes '("esi-skills.read_skills.v1")
                                   :granted-scopes '())))
    (t:true (typep condition 'eve-sso-error))
    (t:true (typep condition 'eve-sso-insufficient-scopes))))

;;; Token Refresh Tests
;;; Regression coverage for the silent-empty-refresh defect: a refresh that yields
;;; no usable access token must signal rather than installing an empty token.

(t:define-test refresh-without-usable-token-signals
  "A refresh that completes but yields no usable access token signals
EVE-SSO-TOKEN-REFRESH-FAILED instead of installing an empty token, and leaves the
existing token untouched. The refresh now runs for real, so this stubs a refresh that
returns an oauth session carrying no access token (e.g. a 2xx with no token in the
body) — the post-build guard's job is to reject it rather than install an empty token."
  (let* ((client (make-oauth-client :client-id "test-id" :client-secret "test-secret"))
         (manager (make-token-manager client :storage-path nil))
         (now (get-universal-time))
         ;; An already-expired token that still carries a refresh token, so
         ;; get-valid-access-token takes the refresh path with no valid fallback.
         (existing (eve-gate.auth::%make-token-info
                    :access-token "old-access-token"
                    :refresh-token "dead-refresh-token"
                    :expires-at (- now 100)
                    :obtained-at (- now 1300)))
         (saved (fdefinition 'ciao:oauth2/refresh-token)))
    (setf (eve-gate.auth::token-manager-token manager) existing)
    (unwind-protect
         (progn
           ;; Stub a refresh that completes without an access token: the access-token
           ;; slot stays NIL and the (future) expiration makes the read-back return NIL.
           (setf (fdefinition 'ciao:oauth2/refresh-token)
                 (lambda (auth-server ciao-client refresh-token)
                   (declare (ignore refresh-token))
                   (let ((o (make-instance 'ciao:oauth2
                                           :auth-server auth-server :client ciao-client)))
                     (setf (slot-value o 'ciao::expiration) (+ (get-universal-time) 1200))
                     o)))
           ;; No usable token results: signal, not a silent empty install.
           (t:fail (get-valid-access-token manager) 'eve-sso-token-refresh-failed)
           ;; The manager's token was NOT replaced by an empty token.
           (t:is eq existing (eve-gate.auth::token-manager-token manager))
           (t:is string= "old-access-token"
                 (token-info-access-token (eve-gate.auth::token-manager-token manager))))
      (setf (fdefinition 'ciao:oauth2/refresh-token) saved))))

(t:define-test refresh-with-usable-token-installs
  "A normal refresh still installs the refreshed token and returns its access token
string (the happy path is preserved)."
  (let* ((client (make-oauth-client :client-id "test-id" :client-secret "test-secret"))
         (manager (make-token-manager client :storage-path nil))
         (now (get-universal-time))
         (existing (eve-gate.auth::%make-token-info
                    :access-token "old-access-token"
                    :refresh-token "live-refresh-token"
                    :expires-at (- now 100)
                    :obtained-at (- now 1300)))
         (original-fn (fdefinition 'eve-gate.auth::refresh-access-token)))
    (setf (eve-gate.auth::token-manager-token manager) existing)
    (unwind-protect
         (progn
           ;; Stub the network boundary with a well-formed refresh result.
           (setf (fdefinition 'eve-gate.auth::refresh-access-token)
                 (lambda (oauth-client &optional refresh-token)
                   (declare (ignore oauth-client refresh-token))
                   (list :access-token "fresh-access-token"
                         :refresh-token "rotated-refresh-token"
                         :expires-in 1200
                         :token-type "Bearer"
                         :character-id 99
                         :character-name "Test Pilot")))
           (let ((returned (get-valid-access-token manager)))
             (t:is string= "fresh-access-token" returned)
             (t:is string= "fresh-access-token"
                   (token-info-access-token (eve-gate.auth::token-manager-token manager)))
             (t:true (eve-gate.auth::token-valid-p
                      (eve-gate.auth::token-manager-token manager)))))
      (setf (fdefinition 'eve-gate.auth::refresh-access-token) original-fn))))

;;; Token Refresh Execution Tests
;;; Regression coverage for the refresh that never executed: with an existing CIAO
;;; session, refresh-access-token set the refresh token on the session but never made
;;; the network call, so a long-running token was never renewed and silently went
;;; stale. It must now force a real refresh through ciao:oauth2/refresh-token,
;;; short-circuit only when the current token is still comfortably valid, and tag a
;;; dead/revoked refresh token (invalid_grant) distinctly from a transient failure.

(defmacro with-stubbed-fns ((&rest bindings) &body body)
  "Temporarily install global function definitions for the extent of BODY, restoring
them afterward. Each binding is (function-name lambda-form). Used to drive the real
refresh path with the CIAO/network boundary replaced."
  (let ((saves (loop for b in bindings collect (gensym "SAVE"))))
    `(let ,(loop for s in saves for b in bindings
                 collect `(,s (fdefinition ',(first b))))
       (unwind-protect
            (progn
              ,@(loop for b in bindings
                      collect `(setf (fdefinition ',(first b)) ,(second b)))
              ,@body)
         ,@(loop for s in saves for b in bindings
                 collect `(setf (fdefinition ',(first b)) ,s))))))

(defun stale-ciao-oauth (client)
  "A CIAO oauth2 object as a long-running session holds it: an expired access token.
This is the state in which the old code silently failed to refresh."
  (let ((o (make-instance 'ciao:oauth2
                          :auth-server (eve-gate.auth::oauth-client-auth-server client)
                          :client (eve-gate.auth::oauth-client-ciao-client client))))
    (setf (slot-value o 'ciao::access-token) "stale-access-token")
    (setf (slot-value o 'ciao::refresh-token) "stored-refresh-token")
    (setf (slot-value o 'ciao::expiration) (- (get-universal-time) 100))
    o))

(defun fresh-ciao-oauth (client)
  "A CIAO oauth2 object representing a successful refresh: a live access token."
  (let ((o (make-instance 'ciao:oauth2
                          :auth-server (eve-gate.auth::oauth-client-auth-server client)
                          :client (eve-gate.auth::oauth-client-ciao-client client))))
    (setf (slot-value o 'ciao::access-token) "fresh-access-token")
    (setf (slot-value o 'ciao::refresh-token) "rotated-refresh-token")
    (setf (slot-value o 'ciao::expiration) (+ (get-universal-time) 1200))
    o))

(defun dex-http-failure (status body)
  "A fully-formed dexador HTTP failure condition, as dexador itself raises it (all
slots bound, so the production handler can print it while classifying)."
  (make-condition 'dexador.error:http-request-failed
                  :status status :body body :headers nil :method :post
                  :uri (quri:uri "https://login.eveonline.com/v2/oauth/token")))

(t:define-test refresh-executes-network-refresh
  "With an existing CIAO session and an expired token, get-valid-access-token forces a
real refresh through ciao:oauth2/refresh-token and returns the renewed token."
  (let* ((client (make-oauth-client :client-id "id" :client-secret "secret"))
         (manager (make-token-manager client :storage-path nil))
         (now (get-universal-time))
         (called nil))
    (setf (eve-gate.auth::oauth-client-ciao-oauth client) (stale-ciao-oauth client))
    (setf (eve-gate.auth::token-manager-token manager)
          (eve-gate.auth::%make-token-info :access-token "stale-access-token"
                                           :refresh-token "stored-refresh-token"
                                           :expires-at (- now 100)
                                           :obtained-at (- now 1300)))
    (with-stubbed-fns
        ((ciao:oauth2/refresh-token
          (lambda (auth-server ciao-client refresh-token)
            (declare (ignore auth-server ciao-client refresh-token))
            (setf called t)
            (fresh-ciao-oauth client)))
         (eve-gate.auth::verify-access-token
          (lambda (access-token) (declare (ignore access-token)) (values 99 "Test Pilot"))))
      (let ((returned (get-valid-access-token manager)))
        (t:true called)
        (t:is string= "fresh-access-token" returned)
        (t:is string= "fresh-access-token"
              (token-info-access-token (eve-gate.auth::token-manager-token manager)))))))

(t:define-test refresh-short-circuits-when-token-fresh
  "A still-valid token outside the refresh threshold is returned without any refresh."
  (let* ((client (make-oauth-client :client-id "id" :client-secret "secret"))
         (manager (make-token-manager client :storage-path nil))
         (now (get-universal-time))
         (called nil))
    (setf (eve-gate.auth::oauth-client-ciao-oauth client) (stale-ciao-oauth client))
    (setf (eve-gate.auth::token-manager-token manager)
          (eve-gate.auth::%make-token-info :access-token "current-access-token"
                                           :refresh-token "stored-refresh-token"
                                           :expires-at (+ now 1000) ; well beyond the 300s threshold
                                           :obtained-at now))
    (with-stubbed-fns
        ((ciao:oauth2/refresh-token
          (lambda (a c r) (declare (ignore a c r)) (setf called t) (fresh-ciao-oauth client))))
      (let ((returned (get-valid-access-token manager)))
        (t:false called)
        (t:is string= "current-access-token" returned)))))

(t:define-test refresh-renews-within-threshold
  "A still-valid token inside the refresh threshold is proactively renewed via a real
refresh. This fails against the inverted-guard code, which never refreshed an existing
session."
  (let* ((client (make-oauth-client :client-id "id" :client-secret "secret"))
         (manager (make-token-manager client :storage-path nil))
         (now (get-universal-time))
         (called nil))
    (setf (eve-gate.auth::oauth-client-ciao-oauth client) (stale-ciao-oauth client))
    (setf (eve-gate.auth::token-manager-token manager)
          (eve-gate.auth::%make-token-info :access-token "current-access-token"
                                           :refresh-token "stored-refresh-token"
                                           :expires-at (+ now 100) ; inside the 300s threshold, not yet expired
                                           :obtained-at now))
    (with-stubbed-fns
        ((ciao:oauth2/refresh-token
          (lambda (a c r) (declare (ignore a c r)) (setf called t) (fresh-ciao-oauth client)))
         (eve-gate.auth::verify-access-token
          (lambda (at) (declare (ignore at)) (values 99 "Test Pilot"))))
      (let ((returned (get-valid-access-token manager)))
        (t:true called)
        (t:is string= "fresh-access-token" returned)))))

(t:define-test dead-refresh-token-tagged-invalid-grant
  "A refresh whose HTTP 400 body carries invalid_grant raises eve-sso-token-refresh-failed
tagged :invalid-grant (the operator-relink signal); every other failure stays
:refresh-error so a transient blip is never mistaken for a dead token."
  (let ((client (make-oauth-client :client-id "id" :client-secret "secret")))
    (setf (eve-gate.auth::oauth-client-ciao-oauth client) (stale-ciao-oauth client))
    (flet ((tag-for (failure)
             (with-stubbed-fns
                 ((ciao:oauth2/refresh-token
                   (lambda (a c r) (declare (ignore a c r)) (error failure))))
               (handler-case
                   (progn (eve-gate.auth::refresh-access-token client "stored-refresh-token")
                          :no-signal)
                 (eve-sso-token-refresh-failed (c) (eve-sso-error-type c))))))
      ;; Positively invalid_grant -> :invalid-grant (the :wedged trigger).
      (t:is eq :invalid-grant
            (tag-for (dex-http-failure 400 "{\"error\":\"invalid_grant\"}")))
      ;; A 400 with a different OAuth error -> transient.
      (t:is eq :refresh-error
            (tag-for (dex-http-failure 400 "{\"error\":\"server_error\"}")))
      ;; A 5xx -> transient.
      (t:is eq :refresh-error
            (tag-for (dex-http-failure 503 "service unavailable")))
      ;; A non-HTTP failure (e.g. network) -> transient.
      (t:is eq :refresh-error
            (tag-for (make-condition 'simple-error
                                     :format-control "connection refused"))))))
