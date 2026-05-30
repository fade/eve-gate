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
                #:eve-sso-token-refresh-failed)
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
  "A refresh that produces no usable access token signals
EVE-SSO-TOKEN-REFRESH-FAILED instead of installing an empty token, and leaves the
existing token untouched."
  (let* ((client (make-oauth-client :client-id "test-id" :client-secret "test-secret"))
         (manager (make-token-manager client :storage-path nil))
         (now (get-universal-time))
         ;; An already-expired token that still carries a refresh token, so
         ;; get-valid-access-token takes the refresh path.
         (existing (eve-gate.auth::%make-token-info
                    :access-token "old-access-token"
                    :refresh-token "dead-refresh-token"
                    :expires-at (- now 100)
                    :obtained-at (- now 1300))))
    (setf (eve-gate.auth::token-manager-token manager) existing)
    ;; Wire a CIAO oauth object holding no access token and an expired (numeric)
    ;; expiration. This reproduces the live "refresh never executes" shape: the real
    ;; refresh path reads the access token back as NIL with no error.
    (let ((ciao-oauth (make-instance 'ciao:oauth2
                                     :auth-server (eve-gate.auth::oauth-client-auth-server client)
                                     :client (eve-gate.auth::oauth-client-ciao-client client))))
      (setf (slot-value ciao-oauth 'ciao::expiration) (- now 100))
      (setf (slot-value ciao-oauth 'ciao::refresh-token) "dead-refresh-token")
      (setf (eve-gate.auth::oauth-client-ciao-oauth client) ciao-oauth))
    ;; The refresh cannot produce a usable token: signal, not a silent empty install.
    (t:fail (get-valid-access-token manager) 'eve-sso-token-refresh-failed)
    ;; The manager's token was NOT replaced by an empty token.
    (t:is eq existing (eve-gate.auth::token-manager-token manager))
    (t:is string= "old-access-token"
          (token-info-access-token (eve-gate.auth::token-manager-token manager)))))

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
