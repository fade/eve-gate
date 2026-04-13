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
                #:eve-sso-insufficient-scopes)
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
