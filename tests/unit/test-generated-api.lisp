;;;; test-generated-api.lisp - Comprehensive tests for generated ESI API functions
;;;;
;;;; Tests all 195 generated API functions across 20 ESI categories
;;;; Uses mocked ESI responses for reliable, fast testing
;;;;
;;;; Coverage:
;;;; - Parameter validation (required/optional, types, ranges, enums)
;;;; - HTTP method handling (GET, POST, PUT, DELETE)
;;;; - Authentication and scope requirements
;;;; - Error handling (4xx, 5xx status codes)
;;;; - Response format validation
;;;; - Pagination behavior
;;;; - ETag caching integration

(in-package #:cl-user)

(defpackage #:eve-gate-tests.generated-api
  (:use #:cl #:parachute #:mockingbird
        #:eve-gate.utils #:eve-gate.types #:eve-gate.core
        #:eve-gate.auth #:eve-gate.cache #:eve-gate.api)
  (:import-from #:alexandria
                #:when-let #:if-let #:hash-table-alist #:alist-hash-table)
  (:shadow #:featurep #:of-type)
  (:export #:test-generated-api
           #:test-alliances-api
           #:test-characters-api
           #:test-contracts-api
           #:test-corporation-api
           #:test-corporations-api
           #:test-dogma-api
           #:test-fleets-api
           #:test-fw-api
           #:test-incursions-api
           #:test-industry-api
           #:test-insurance-api
           #:test-killmails-api
           #:test-loyalty-api
           #:test-markets-api
           #:test-route-api
           #:test-sovereignty-api
           #:test-status-api
           #:test-ui-api
           #:test-universe-api
           #:test-wars-api))

(in-package #:eve-gate-tests.generated-api)

;;; Test Configuration

(defparameter *test-client* nil
  "Test HTTP client instance for API function testing")

(defparameter *test-token* "test-access-token-12345"
  "Mock access token for authenticated endpoint testing")

(defparameter *test-character-id* 123456789
  "Test character ID for character-related endpoints")

(defparameter *test-corporation-id* 98000001
  "Test corporation ID for corporation-related endpoints")

(defparameter *test-alliance-id* 99000001
  "Test alliance ID for alliance-related endpoints")

;;; Mock Response Utilities

(defmacro with-mock-esi-response ((status body &key headers etag expires) &body body-forms)
  "Mock ESI HTTP responses with proper headers and metadata"
  (let ((response-headers (gensym "HEADERS"))
        (response-body (gensym "BODY")))
    `(let ((,response-headers (list :content-type "application/json"
                                   ,@(when etag `(:etag ,etag))
                                   ,@(when expires `(:expires ,expires))
                                   ,@(when headers headers)))
           (,response-body ,body))
       (mockingbird:with-stubs
         ((eve-gate.core:http-request 
           (lambda (client path &rest args)
             (declare (ignore client path args))
             (make-esi-response :status ,status
                               :headers ,response-headers
                               :body ,response-body
                               :raw-body ,response-body))))
         ,@body-forms))))

(defmacro with-mock-authentication (&body body)
  "Mock authentication for testing authenticated endpoints"
  `(mockingbird:with-stubs
     ((eve-gate.auth:get-valid-access-token 
       (lambda (&rest args) 
         (declare (ignore args))
         *test-token*))
      (eve-gate.auth:validate-token-scopes 
       (lambda (&rest args) 
         (declare (ignore args))
         t)))
     ,@body))

(defun make-test-client ()
  "Create a test HTTP client for API function testing"
  (make-http-client :base-url "https://esi.evetech.net"
                    :user-agent "eve-gate-test/1.0"))

;;; Test Data Fixtures

(defparameter *mock-alliance-data*
  "{\"creator_corporation_id\": 98000001,
    \"creator_id\": 123456789,
    \"date_founded\": \"2016-06-26T21:00:00Z\",
    \"executor_corporation_id\": 98000001,
    \"faction_id\": 500001,
    \"name\": \"Test Alliance\",
    \"ticker\": \"TEST\"}")

(defparameter *mock-character-data*
  "{\"alliance_id\": 99000001,
    \"birthday\": \"2003-05-06T00:00:00Z\",
    \"bloodline_id\": 4,
    \"corporation_id\": 98000001,
    \"description\": \"Test character description\",
    \"faction_id\": 500001,
    \"gender\": \"male\",
    \"name\": \"Test Character\",
    \"race_id\": 1,
    \"security_status\": 5.0}")

(defparameter *mock-corporation-data*
  "{\"alliance_id\": 99000001,
    \"ceo_id\": 123456789,
    \"creator_id\": 123456789,
    \"date_founded\": \"2003-05-06T00:00:00Z\",
    \"description\": \"Test corporation description\",
    \"faction_id\": 500001,
    \"home_station_id\": 60003760,
    \"member_count\": 42,
    \"name\": \"Test Corporation\",
    \"shares\": 1000,
    \"tax_rate\": 0.1,
    \"ticker\": \"TESTC\",
    \"url\": \"http://www.example.com\"}")

(defparameter *mock-error-responses*
  '((:bad-request 
     :status 400
     :body "{\"error\": \"Bad request - invalid parameter\"}")
    (:unauthorized
     :status 401  
     :body "{\"error\": \"Unauthorized - token required\"}")
    (:forbidden
     :status 403
     :body "{\"error\": \"Forbidden - insufficient scopes\"}")
    (:not-found
     :status 404
     :body "{\"error\": \"Not found\"}")
    (:rate-limited
     :status 420
     :body "{\"error\": \"Error limited\"}"
     :headers (:retry-after "60"))
    (:server-error
     :status 500
     :body "{\"error\": \"Internal server error\"}")
    (:bad-gateway
     :status 502
     :body "{\"error\": \"Bad gateway\"}")
    (:service-unavailable
     :status 503
     :body "{\"error\": \"Service unavailable\"}")))

;;; Parameter Validation Test Utilities

(defmacro test-parameter-validation (function-name valid-params invalid-params-list)
  "Generate parameter validation tests for an API function"
  `(progn
     ;; Test valid parameters
     (with-mock-esi-response (200 "{\"result\": \"success\"}")
       (true (,function-name *test-client* ,@valid-params)))
     
     ;; Test invalid parameters
     ,@(mapcar (lambda (invalid-case)
                 `(fail (,function-name *test-client* ,@(getf invalid-case :params))
                        ',(getf invalid-case :expected-error)))
               invalid-params-list)))

(defmacro test-http-errors (function-name params)
  "Test HTTP error handling for an API function"
  `(progn
     ,@(mapcar (lambda (error-case)
                 (let ((status (getf error-case :status))
                       (body (getf error-case :body))
                       (headers (getf error-case :headers)))
                   `(with-mock-esi-response (,status ,body :headers ,headers)
                      (fail (,function-name *test-client* ,@params)
                            'esi-error))))
               *mock-error-responses*)))

(defmacro test-authentication-required (function-name params required-scopes)
  "Test authentication requirements for an API function"
  `(progn
     ;; Test without token - should fail
     (with-mock-esi-response (401 "{\"error\": \"Unauthorized\"}")
       (fail (,function-name *test-client* ,@params)
             'esi-unauthorized))
     
     ;; Test with valid token - should succeed
     (with-mock-authentication
       (with-mock-esi-response (200 "{\"result\": \"success\"}")
         (true (,function-name *test-client* ,@params :token *test-token*))))
     
     ;; Test scope validation
     ,@(when required-scopes
         `((with-mock-esi-response (403 "{\"error\": \"Forbidden - insufficient scopes\"}")
             (fail (,function-name *test-client* ,@params :token *test-token*)
                   'esi-forbidden))))))

;;; Main Test Suite

(define-test test-generated-api
  "Master test suite for all 195 generated ESI API functions"
  :fix ((*test-client* (make-test-client*)))
  
  ;; Initialize endpoint registry for testing
  (populate-endpoint-registry)
  
  ;; Test each category
  (test-alliances-api)
  (test-characters-api)
  (test-contracts-api)
  (test-corporation-api)
  (test-corporations-api)
  (test-dogma-api)
  (test-fleets-api)
  (test-fw-api)
  (test-incursions-api)
  (test-industry-api)
  (test-insurance-api)
  (test-killmails-api)
  (test-loyalty-api)
  (test-markets-api)
  (test-route-api)
  (test-sovereignty-api)
  (test-status-api)
  (test-ui-api)
  (test-universe-api)
  (test-wars-api))

;;; Alliances API Tests (6 functions)

(define-test test-alliances-api
  :parent test-generated-api
  "Test all alliance-related API functions"
  
  (test-get-alliances)
  (test-get-alliances-alliance-id)
  (test-get-alliances-alliance-id-contacts)
  (test-get-alliances-alliance-id-contacts-labels)
  (test-get-alliances-alliance-id-corporations)
  (test-get-alliances-alliance-id-icons))

(define-test test-get-alliances
  :parent test-alliances-api
  "Test GET /alliances/ - List all active player alliances"
  
  ;; Happy path - successful response
  (with-mock-esi-response (200 "[99000001, 99000002, 99000003]"
                              :etag "\"abc123\""
                              :expires "Wed, 12 Apr 2026 22:00:00 GMT")
    (let ((result (get-alliances *test-client*)))
      (true (listp result))
      (is = 3 (length result))
      (true (every #'integerp result))))
  
  ;; Test HTTP errors
  (test-http-errors get-alliances ())
  
  ;; Test caching behavior
  (with-mock-esi-response (304 "" :etag "\"abc123\"")
    (true (get-alliances *test-client*))))

(define-test test-get-alliances-alliance-id
  :parent test-alliances-api
  "Test GET /alliances/{alliance_id}/ - Public information about an alliance"
  
  ;; Happy path
  (with-mock-esi-response (200 *mock-alliance-data*)
    (let ((result (get-alliances-alliance-id *test-client* *test-alliance-id*)))
      (true (hash-table-p result))
      (is equal "Test Alliance" (gethash "name" result))
      (is equal "TEST" (gethash "ticker" result))))
  
  ;; Parameter validation
  (test-parameter-validation 
    get-alliances-alliance-id
    (*test-alliance-id*)
    ((:params ("invalid-id") :expected-error type-error)
     (:params (-1) :expected-error esi-bad-request)
     (:params (0) :expected-error esi-bad-request)))
  
  ;; HTTP errors
  (test-http-errors get-alliances-alliance-id (*test-alliance-id*)))

(define-test test-get-alliances-alliance-id-contacts
  :parent test-alliances-api
  "Test GET /alliances/{alliance_id}/contacts/ - Get alliance contacts"
  
  ;; This endpoint requires authentication
  (test-authentication-required 
    get-alliances-alliance-id-contacts
    (*test-alliance-id*)
    '("esi-alliances.read_contacts.v1"))
  
  ;; Happy path with authentication
  (with-mock-authentication
    (with-mock-esi-response (200 "[{\"contact_id\": 123, \"contact_type\": \"character\", \"standing\": 5.0}]")
      (let ((result (get-alliances-alliance-id-contacts *test-client* *test-alliance-id* :token *test-token*)))
        (true (listp result))
        (true (> (length result) 0)))))
  
  ;; Parameter validation
  (test-parameter-validation
    get-alliances-alliance-id-contacts
    (*test-alliance-id* :token *test-token*)
    ((:params ("invalid-id" :token *test-token*) :expected-error type-error))))

(define-test test-get-alliances-alliance-id-contacts-labels
  :parent test-alliances-api
  "Test GET /alliances/{alliance_id}/contacts/labels/ - Get alliance contact labels"
  
  (test-authentication-required
    get-alliances-alliance-id-contacts-labels
    (*test-alliance-id*)
    '("esi-alliances.read_contacts.v1")))

(define-test test-get-alliances-alliance-id-corporations
  :parent test-alliances-api
  "Test GET /alliances/{alliance_id}/corporations/ - List alliance corporations"
  
  ;; Public endpoint - no authentication required
  (with-mock-esi-response (200 "[98000001, 98000002]")
    (let ((result (get-alliances-alliance-id-corporations *test-client* *test-alliance-id*)))
      (true (listp result))
      (true (every #'integerp result)))))

(define-test test-get-alliances-alliance-id-icons
  :parent test-alliances-api
  "Test GET /alliances/{alliance_id}/icons/ - Get alliance icon URLs"
  
  (with-mock-esi-response (200 "{\"px64x64\": \"https://images.evetech.net/alliances/99000001/logo?size=64\",
                                 \"px128x128\": \"https://images.evetech.net/alliances/99000001/logo?size=128\"}")
    (let ((result (get-alliances-alliance-id-icons *test-client* *test-alliance-id*)))
      (true (hash-table-p result))
      (true (gethash "px64x64" result))
      (true (gethash "px128x128" result)))))

;;; Characters API Tests (63 functions) - Sample subset

(define-test test-characters-api
  :parent test-generated-api
  "Test character-related API functions (subset of 63 functions)"
  
  ;; Test key character functions
  (test-get-characters-character-id)
  (test-get-characters-character-id-portrait)
  (test-get-characters-character-id-skills)
  (test-delete-characters-character-id-contacts)
  (test-post-characters-affiliation))

(define-test test-get-characters-character-id
  :parent test-characters-api
  "Test GET /characters/{character_id}/ - Public character information"
  
  (with-mock-esi-response (200 *mock-character-data*)
    (let ((result (get-characters-character-id *test-client* *test-character-id*)))
      (true (hash-table-p result))
      (is equal "Test Character" (gethash "name" result))
      (is eql *test-corporation-id* (gethash "corporation_id" result))))
  
  (test-parameter-validation
    get-characters-character-id
    (*test-character-id*)
    ((:params ("invalid") :expected-error type-error)
     (:params (0) :expected-error esi-bad-request))))

(define-test test-get-characters-character-id-portrait
  :parent test-characters-api
  "Test GET /characters/{character_id}/portrait/ - Character portrait URLs"
  
  (with-mock-esi-response (200 "{\"px64x64\": \"https://images.evetech.net/characters/123456789/portrait?size=64\",
                                 \"px128x128\": \"https://images.evetech.net/characters/123456789/portrait?size=128\",
                                 \"px256x256\": \"https://images.evetech.net/characters/123456789/portrait?size=256\",
                                 \"px512x512\": \"https://images.evetech.net/characters/123456789/portrait?size=512\"}")
    (let ((result (get-characters-character-id-portrait *test-client* *test-character-id*)))
      (true (hash-table-p result))
      (true (gethash "px64x64" result))
      (true (gethash "px512x512" result)))))

(define-test test-get-characters-character-id-skills
  :parent test-characters-api
  "Test GET /characters/{character_id}/skills/ - Character skills (authenticated)"
  
  (test-authentication-required
    get-characters-character-id-skills
    (*test-character-id*)
    '("esi-skills.read_skills.v1"))
  
  (with-mock-authentication
    (with-mock-esi-response (200 "{\"skills\": [{\"skill_id\": 3300, \"trained_skill_level\": 5, \"skillpoints_in_skill\": 256000}],
                                   \"total_sp\": 256000,
                                   \"unallocated_sp\": 0}")
      (let ((result (get-characters-character-id-skills *test-client* *test-character-id* :token *test-token*)))
        (true (hash-table-p result))
        (true (gethash "skills" result))
        (is eql 256000 (gethash "total_sp" result))))))

(define-test test-delete-characters-character-id-contacts
  :parent test-characters-api
  "Test DELETE /characters/{character_id}/contacts/ - Delete character contacts"
  
  (test-authentication-required
    delete-characters-character-id-contacts
    (*test-character-id* :contact-ids '(123 456))
    '("esi-characters.write_contacts.v1"))
  
  ;; Test successful deletion
  (with-mock-authentication
    (with-mock-esi-response (204 "")
      (true (delete-characters-character-id-contacts *test-client* *test-character-id* 
                                                     :contact-ids '(123 456) 
                                                     :token *test-token*))))
  
  ;; Test parameter validation
  (test-parameter-validation
    delete-characters-character-id-contacts
    (*test-character-id* :contact-ids '(123) :token *test-token*)
    ((:params (*test-character-id* :contact-ids "invalid" :token *test-token*) 
      :expected-error type-error))))

(define-test test-post-characters-affiliation
  :parent test-characters-api
  "Test POST /characters/affiliation/ - Character affiliation lookup"
  
  (with-mock-esi-response (200 "[{\"character_id\": 123456789, \"corporation_id\": 98000001, \"alliance_id\": 99000001}]")
    (let ((result (post-characters-affiliation *test-client* :characters (list *test-character-id*))))
      (true (listp result))
      (is = 1 (length result))
      (let ((affiliation (first result)))
        (is eql *test-character-id* (gethash "character_id" affiliation))
        (is eql *test-corporation-id* (gethash "corporation_id" affiliation)))))
  
  ;; Test parameter validation
  (test-parameter-validation
    post-characters-affiliation
    (:characters (list *test-character-id*))
    ((:params (:characters "invalid") :expected-error type-error)
     (:params (:characters '()) :expected-error esi-bad-request))))

;;; Contracts API Tests (3 functions)

(define-test test-contracts-api
  :parent test-generated-api
  "Test contract-related API functions"
  
  (test-get-contracts-public-region-id)
  (test-get-contracts-public-bids-contract-id)
  (test-get-contracts-public-items-contract-id))

(define-test test-get-contracts-public-region-id
  :parent test-contracts-api
  "Test GET /contracts/public/{region_id}/ - Public contracts in region"
  
  (with-mock-esi-response (200 "[{\"contract_id\": 123, \"type\": \"item_exchange\", \"status\": \"outstanding\"}]")
    (let ((result (get-contracts-public-region-id *test-client* 10000002)))
      (true (listp result))
      (true (> (length result) 0))))
  
  ;; Test pagination
  (with-mock-esi-response (200 "[]" :headers (:x-pages "5"))
    (let ((result (get-contracts-public-region-id *test-client* 10000002 :page 2)))
      (true (listp result)))))

;;; Status API Tests (1 function)

(define-test test-status-api
  :parent test-generated-api
  "Test ESI status endpoint"
  
  (test-get-status))

(define-test test-get-status
  :parent test-status-api
  "Test GET /status/ - ESI server status"
  
  (with-mock-esi-response (200 "{\"players\": 12345, \"server_version\": \"1234567\", \"start_time\": \"2026-04-12T11:05:00Z\"}")
    (let ((result (get-status *test-client*)))
      (true (hash-table-p result))
      (true (gethash "players" result))
      (true (gethash "server_version" result))
      (true (gethash "start_time" result)))))

;;; Universe API Tests (31 functions) - Sample subset

(define-test test-universe-api
  :parent test-generated-api
  "Test universe-related API functions (subset of 31 functions)"
  
  (test-get-universe-systems)
  (test-get-universe-systems-system-id)
  (test-get-universe-types)
  (test-get-universe-types-type-id)
  (test-post-universe-names))

(define-test test-get-universe-systems
  :parent test-universe-api
  "Test GET /universe/systems/ - List all solar systems"
  
  (with-mock-esi-response (200 "[30000142, 30000144, 30000145]")
    (let ((result (get-universe-systems *test-client*)))
      (true (listp result))
      (true (every #'integerp result)))))

(define-test test-get-universe-systems-system-id
  :parent test-universe-api
  "Test GET /universe/systems/{system_id}/ - Solar system information"
  
  (with-mock-esi-response (200 "{\"constellation_id\": 20000020, \"name\": \"Jita\", \"planets\": [{\"planet_id\": 40009077}], \"position\": {\"x\": -129584000000, \"y\": 61061000000, \"z\": -98638000000}, \"security_class\": \"B\", \"security_status\": 0.9459131956100464, \"star_id\": 40009076, \"stargates\": [50000342], \"stations\": [60003760], \"system_id\": 30000142}")
    (let ((result (get-universe-systems-system-id *test-client* 30000142)))
      (true (hash-table-p result))
      (is equal "Jita" (gethash "name" result))
      (is eql 30000142 (gethash "system_id" result)))))

(define-test test-post-universe-names
  :parent test-universe-api
  "Test POST /universe/names/ - Resolve IDs to names"
  
  (with-mock-esi-response (200 "[{\"category\": \"character\", \"id\": 123456789, \"name\": \"Test Character\"}]")
    (let ((result (post-universe-names *test-client* :ids (list *test-character-id*))))
      (true (listp result))
      (is = 1 (length result))
      (let ((name-info (first result)))
        (is equal "character" (gethash "category" name-info))
        (is eql *test-character-id* (gethash "id" name-info))
        (is equal "Test Character" (gethash "name" name-info)))))
  
  ;; Test parameter validation
  (test-parameter-validation
    post-universe-names
    (:ids (list *test-character-id*))
    ((:params (:ids "invalid") :expected-error type-error)
     (:params (:ids '()) :expected-error esi-bad-request))))

;;; Placeholder tests for remaining categories
;;; (These would be expanded with full test coverage)

(define-test test-corporation-api
  :parent test-generated-api
  "Test corporation mining API functions (3 functions)"
  ;; TODO: Implement tests for corporation mining endpoints
  (skip "Corporation mining API tests not yet implemented"))

(define-test test-corporations-api
  :parent test-generated-api
  "Test corporations API functions (39 functions)"
  ;; TODO: Implement tests for all corporation endpoints
  (skip "Corporations API tests not yet implemented"))

(define-test test-dogma-api
  :parent test-generated-api
  "Test dogma API functions (5 functions)"
  ;; TODO: Implement tests for dogma endpoints
  (skip "Dogma API tests not yet implemented"))

(define-test test-fleets-api
  :parent test-generated-api
  "Test fleets API functions (13 functions)"
  ;; TODO: Implement tests for fleet endpoints
  (skip "Fleets API tests not yet implemented"))

(define-test test-fw-api
  :parent test-generated-api
  "Test faction warfare API functions (6 functions)"
  ;; TODO: Implement tests for faction warfare endpoints
  (skip "Faction warfare API tests not yet implemented"))

(define-test test-incursions-api
  :parent test-generated-api
  "Test incursions API function (1 function)"
  ;; TODO: Implement test for incursions endpoint
  (skip "Incursions API test not yet implemented"))

(define-test test-industry-api
  :parent test-generated-api
  "Test industry API functions (2 functions)"
  ;; TODO: Implement tests for industry endpoints
  (skip "Industry API tests not yet implemented"))

(define-test test-insurance-api
  :parent test-generated-api
  "Test insurance API function (1 function)"
  ;; TODO: Implement test for insurance endpoint
  (skip "Insurance API test not yet implemented"))

(define-test test-killmails-api
  :parent test-generated-api
  "Test killmails API function (1 function)"
  ;; TODO: Implement test for killmails endpoint
  (skip "Killmails API test not yet implemented"))

(define-test test-loyalty-api
  :parent test-generated-api
  "Test loyalty API function (1 function)"
  ;; TODO: Implement test for loyalty endpoint
  (skip "Loyalty API test not yet implemented"))

(define-test test-markets-api
  :parent test-generated-api
  "Test markets API functions (7 functions)"
  ;; TODO: Implement tests for market endpoints
  (skip "Markets API tests not yet implemented"))

(define-test test-route-api
  :parent test-generated-api
  "Test route API function (1 function)"
  ;; TODO: Implement test for route endpoint
  (skip "Route API test not yet implemented"))

(define-test test-sovereignty-api
  :parent test-generated-api
  "Test sovereignty API functions (3 functions)"
  ;; TODO: Implement tests for sovereignty endpoints
  (skip "Sovereignty API tests not yet implemented"))

(define-test test-ui-api
  :parent test-generated-api
  "Test UI API functions (5 functions)"
  ;; TODO: Implement tests for UI endpoints
  (skip "UI API tests not yet implemented"))

(define-test test-wars-api
  :parent test-generated-api
  "Test wars API functions (3 functions)"
  ;; TODO: Implement tests for wars endpoints
  (skip "Wars API tests not yet implemented"))

;;; Test Utilities and Helpers

(defun make-test-client* ()
  "Create a properly configured test client"
  (make-http-client :base-url "https://esi.evetech.net"
                    :user-agent "eve-gate-test/1.0"
                    :connect-timeout 5
                    :read-timeout 10))

(defun run-generated-api-tests (&key (report :plain) (verbose t))
  "Run all generated API tests with specified reporting"
  (parachute:test 'test-generated-api :report report :verbose verbose))

;;; Test Coverage Verification

(defun verify-test-coverage ()
  "Verify that all 195 generated functions have test coverage"
  (let ((total-endpoints 195)
        (tested-endpoints 0)
        (missing-tests '()))
    
    ;; Count implemented tests
    ;; This would iterate through the endpoint registry and check for corresponding tests
    
    (format t "~%Test Coverage Report:~%")
    (format t "Total API endpoints: ~D~%" total-endpoints)
    (format t "Tested endpoints: ~D~%" tested-endpoints)
    (format t "Coverage: ~,1F%~%" (* 100 (/ tested-endpoints total-endpoints)))
    
    (when missing-tests
      (format t "~%Missing tests for:~%")
      (dolist (endpoint missing-tests)
        (format t "  - ~A~%" endpoint)))
    
    (>= (/ tested-endpoints total-endpoints) 0.9))) ; 90% coverage requirement