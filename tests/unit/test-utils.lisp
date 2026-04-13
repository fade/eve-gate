;;;; test-utils.lisp - Common testing utilities for eve-gate test suite
;;;;
;;;; Provides shared utilities, fixtures, and helper functions for testing
;;;; all components of the eve-gate ESI API client library.

(in-package #:cl-user)

(defpackage #:eve-gate-tests.utils
  (:use #:cl #:alexandria #:parachute #:mockingbird
        #:eve-gate.utils #:eve-gate.types #:eve-gate.core
        #:eve-gate.auth #:eve-gate.cache #:eve-gate.api)
  (:export 
   ;; Test configuration
   #:*test-base-url*
   #:*test-user-agent*
   #:*test-timeout*
   
   ;; Test data fixtures
   #:*test-character-id*
   #:*test-corporation-id*
   #:*test-alliance-id*
   #:*test-system-id*
   #:*test-type-id*
   #:*test-token*
   
   ;; Mock response utilities
   #:with-mock-esi-response
   #:with-mock-authentication
   #:with-mock-http-client
   #:make-mock-response
   #:mock-esi-error-response
   
   ;; Test client utilities
   #:make-test-client
   #:make-test-client*
   #:with-test-client
   
   ;; Parameter validation testing
   #:test-parameter-validation
   #:test-required-parameter
   #:test-optional-parameter
   #:test-parameter-type
   #:test-parameter-range
   #:test-parameter-enum
   
   ;; HTTP error testing
   #:test-http-errors
   #:test-authentication-errors
   #:test-rate-limiting
   #:test-server-errors
   
   ;; Response validation
   #:validate-response-structure
   #:validate-json-response
   #:validate-array-response
   #:validate-object-response
   
   ;; Pagination testing
   #:test-pagination-support
   #:test-page-parameter
   
   ;; Caching testing
   #:test-etag-caching
   #:test-cache-headers
   
   ;; Test data generators
   #:generate-test-character-data
   #:generate-test-corporation-data
   #:generate-test-alliance-data
   #:generate-test-error-response
   
   ;; Test reporting
   #:test-coverage-report
   #:endpoint-test-status
   #:missing-test-coverage
   
   ;; Assertion helpers
   #:is-valid-esi-response
   #:is-valid-json
   #:is-valid-character-id
   #:is-valid-corporation-id
   #:is-valid-alliance-id
   #:is-positive-number
   #:is-iso8601-timestamp))

(in-package #:eve-gate-tests.utils)

;;; Test Configuration

(defparameter *test-base-url* "https://esi.evetech.net"
  "Base URL for ESI API testing")

(defparameter *test-user-agent* "eve-gate-test/1.0"
  "User agent string for test requests")

(defparameter *test-timeout* 10
  "Default timeout for test HTTP requests")

;;; Test Data Fixtures

(defparameter *test-character-id* 123456789
  "Standard test character ID")

(defparameter *test-corporation-id* 98000001
  "Standard test corporation ID")

(defparameter *test-alliance-id* 99000001
  "Standard test alliance ID")

(defparameter *test-system-id* 30000142
  "Standard test system ID (Jita)")

(defparameter *test-type-id* 587
  "Standard test type ID (Rifter)")

(defparameter *test-token* "test-access-token-12345"
  "Mock access token for authenticated endpoints")

;;; Mock Response Utilities

(defmacro with-mock-esi-response ((status body &key headers etag expires cache-control) &body body-forms)
  "Mock ESI HTTP responses with proper headers and metadata"
  (let ((response-headers (gensym "HEADERS"))
        (response-body (gensym "BODY")))
    `(let ((,response-headers (list :content-type "application/json"
                                   ,@(when etag `(:etag ,etag))
                                   ,@(when expires `(:expires ,expires))
                                   ,@(when cache-control `(:cache-control ,cache-control))
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
  "Mock authentication system for testing authenticated endpoints"
  `(mockingbird:with-stubs
     ((eve-gate.auth:get-valid-access-token 
       (lambda (&rest args) 
         (declare (ignore args))
         *test-token*))
      (eve-gate.auth:validate-token-scopes 
       (lambda (token scopes)
         (declare (ignore token scopes))
         t))
      (eve-gate.auth:token-expired-p
       (lambda (&rest args)
         (declare (ignore args))
         nil))
      (eve-gate.auth:token-needs-refresh-p
       (lambda (&rest args)
         (declare (ignore args))
         nil)))
     ,@body))

(defmacro with-mock-http-client (&body body)
  "Mock HTTP client for isolated testing"
  `(let ((*test-client* (make-test-client*)))
     ,@body))

(defun make-mock-response (status body &key headers etag expires)
  "Create a mock ESI response object"
  (make-esi-response 
   :status status
   :body body
   :headers (append (list :content-type "application/json")
                   (when etag (list :etag etag))
                   (when expires (list :expires expires))
                   headers)))

(defun mock-esi-error-response (error-type &key message retry-after)
  "Generate mock error responses for different ESI error conditions"
  (case error-type
    (:bad-request 
     (make-mock-response 400 (format nil "{\"error\": \"~A\"}" (or message "Bad request"))))
    (:unauthorized
     (make-mock-response 401 (format nil "{\"error\": \"~A\"}" (or message "Unauthorized"))))
    (:forbidden
     (make-mock-response 403 (format nil "{\"error\": \"~A\"}" (or message "Forbidden"))))
    (:not-found
     (make-mock-response 404 (format nil "{\"error\": \"~A\"}" (or message "Not found"))))
    (:rate-limited
     (make-mock-response 420 (format nil "{\"error\": \"~A\"}" (or message "Error limited"))
                        :headers (when retry-after (list :retry-after (princ-to-string retry-after)))))
    (:server-error
     (make-mock-response 500 (format nil "{\"error\": \"~A\"}" (or message "Internal server error"))))
    (:bad-gateway
     (make-mock-response 502 (format nil "{\"error\": \"~A\"}" (or message "Bad gateway"))))
    (:service-unavailable
     (make-mock-response 503 (format nil "{\"error\": \"~A\"}" (or message "Service unavailable"))))
    (t
     (error "Unknown error type: ~A" error-type))))

;;; Test Client Utilities

(defun make-test-client ()
  "Create a basic test HTTP client"
  (make-http-client :base-url *test-base-url*
                    :user-agent *test-user-agent*
                    :connect-timeout *test-timeout*
                    :read-timeout *test-timeout*))

(defun make-test-client* ()
  "Create a fully configured test HTTP client with middleware"
  (let ((client (make-test-client)))
    ;; Add any test-specific middleware here
    client))

(defmacro with-test-client (client-var &body body)
  "Execute body with a test client bound to client-var"
  `(let ((,client-var (make-test-client*)))
     ,@body))

;;; Parameter Validation Testing

(defmacro test-parameter-validation (function-name valid-params invalid-cases)
  "Generate comprehensive parameter validation tests"
  `(progn
     ;; Test valid parameters
     (with-mock-esi-response (200 "{\"result\": \"success\"}")
       (true (,function-name *test-client* ,@valid-params)))
     
     ;; Test invalid parameters
     ,@(mapcar (lambda (invalid-case)
                 `(fail (,function-name *test-client* ,@(getf invalid-case :params))
                        ',(getf invalid-case :expected-error)))
               invalid-cases)))

(defmacro test-required-parameter (function-name param-name valid-value)
  "Test that a required parameter is properly validated"
  `(progn
     ;; Test with valid value
     (with-mock-esi-response (200 "{\"result\": \"success\"}")
       (true (,function-name *test-client* ,valid-value)))
     
     ;; Test without parameter (should fail)
     (fail (,function-name *test-client*) 'program-error)))

(defmacro test-optional-parameter (function-name required-params optional-param valid-value)
  "Test that an optional parameter works correctly"
  `(progn
     ;; Test without optional parameter
     (with-mock-esi-response (200 "{\"result\": \"success\"}")
       (true (,function-name *test-client* ,@required-params)))
     
     ;; Test with optional parameter
     (with-mock-esi-response (200 "{\"result\": \"success\"}")
       (true (,function-name *test-client* ,@required-params ,optional-param ,valid-value)))))

(defmacro test-parameter-type (function-name params param-index expected-type invalid-values)
  "Test parameter type validation"
  `(progn
     ,@(mapcar (lambda (invalid-value)
                 (let ((test-params (copy-list params)))
                   (setf (nth param-index test-params) invalid-value)
                   `(fail (,function-name *test-client* ,@test-params)
                          'type-error)))
               invalid-values)))

(defmacro test-parameter-range (function-name params param-index min-value max-value)
  "Test parameter range validation"
  `(progn
     ;; Test below minimum
     ,(let ((test-params (copy-list params)))
        (setf (nth param-index test-params) (1- min-value))
        `(fail (,function-name *test-client* ,@test-params)
               'esi-bad-request))
     
     ;; Test above maximum  
     ,(let ((test-params (copy-list params)))
        (setf (nth param-index test-params) (1+ max-value))
        `(fail (,function-name *test-client* ,@test-params)
               'esi-bad-request))
     
     ;; Test valid range
     (with-mock-esi-response (200 "{\"result\": \"success\"}")
       (true (,function-name *test-client* ,@params)))))

;;; HTTP Error Testing

(defmacro test-http-errors (function-name params &key (include-auth-token nil))
  "Test HTTP error handling for an API function"
  (let ((call-params (if include-auth-token
                        `(,@params :token *test-token*)
                        params)))
    `(progn
       ;; Test 400 Bad Request
       (with-mock-esi-response (400 "{\"error\": \"Bad request\"}")
         (fail (,function-name *test-client* ,@call-params) 'esi-bad-request))
       
       ;; Test 404 Not Found
       (with-mock-esi-response (404 "{\"error\": \"Not found\"}")
         (fail (,function-name *test-client* ,@call-params) 'esi-not-found))
       
       ;; Test 420 Rate Limited
       (with-mock-esi-response (420 "{\"error\": \"Error limited\"}" :headers (:retry-after "60"))
         (fail (,function-name *test-client* ,@call-params) 'esi-rate-limit-exceeded))
       
       ;; Test 500 Internal Server Error
       (with-mock-esi-response (500 "{\"error\": \"Internal server error\"}")
         (fail (,function-name *test-client* ,@call-params) 'esi-server-error))
       
       ;; Test 502 Bad Gateway
       (with-mock-esi-response (502 "{\"error\": \"Bad gateway\"}")
         (fail (,function-name *test-client* ,@call-params) 'esi-bad-gateway))
       
       ;; Test 503 Service Unavailable
       (with-mock-esi-response (503 "{\"error\": \"Service unavailable\"}")
         (fail (,function-name *test-client* ,@call-params) 'esi-service-unavailable)))))

(defmacro test-authentication-errors (function-name params required-scopes)
  "Test authentication and authorization errors"
  `(progn
     ;; Test without token
     (with-mock-esi-response (401 "{\"error\": \"Unauthorized\"}")
       (fail (,function-name *test-client* ,@params) 'esi-unauthorized))
     
     ;; Test with invalid token
     (with-mock-esi-response (401 "{\"error\": \"Invalid token\"}")
       (fail (,function-name *test-client* ,@params :token "invalid-token") 'esi-unauthorized))
     
     ;; Test with insufficient scopes
     ,@(when required-scopes
         `((with-mock-esi-response (403 "{\"error\": \"Forbidden - insufficient scopes\"}")
             (mockingbird:with-stubs
               ((eve-gate.auth:validate-token-scopes 
                 (lambda (&rest args) nil)))
               (fail (,function-name *test-client* ,@params :token *test-token*)
                     'esi-forbidden)))))))

;;; Response Validation

(defun validate-response-structure (response expected-keys &key (required-keys nil))
  "Validate that a response has the expected structure"
  (true (hash-table-p response))
  
  ;; Check for expected keys
  (dolist (key expected-keys)
    (true (nth-value 1 (gethash key response))))
  
  ;; Check for required keys
  (dolist (key required-keys)
    (true (gethash key response))))

(defun validate-json-response (response)
  "Validate that a response is valid JSON structure"
  (true (or (hash-table-p response)
           (listp response)
           (stringp response)
           (numberp response)
           (member response '(t nil)))))

(defun validate-array-response (response &key (min-length 0) (max-length nil) (element-validator nil))
  "Validate array response structure"
  (true (listp response))
  (true (>= (length response) min-length))
  (when max-length
    (true (<= (length response) max-length)))
  (when element-validator
    (true (every element-validator response))))

(defun validate-object-response (response required-fields &key (optional-fields nil))
  "Validate object response structure"
  (true (hash-table-p response))
  
  ;; Check required fields
  (dolist (field required-fields)
    (true (nth-value 1 (gethash field response))))
  
  ;; Validate optional fields if present
  (dolist (field optional-fields)
    (when (nth-value 1 (gethash field response))
      (true (gethash field response)))))

;;; Pagination Testing

(defmacro test-pagination-support (function-name params)
  "Test pagination parameter support"
  `(progn
     ;; Test default page (page 1)
     (with-mock-esi-response (200 "[]")
       (true (,function-name *test-client* ,@params)))
     
     ;; Test specific page
     (with-mock-esi-response (200 "[]" :headers (:x-pages "5"))
       (true (,function-name *test-client* ,@params :page 2)))
     
     ;; Test invalid page number
     (fail (,function-name *test-client* ,@params :page 0) 'esi-bad-request)
     (fail (,function-name *test-client* ,@params :page -1) 'esi-bad-request)))

;;; Caching Testing

(defmacro test-etag-caching (function-name params)
  "Test ETag caching behavior"
  `(progn
     ;; Test initial request with ETag
     (with-mock-esi-response (200 "{\"data\": \"test\"}" :etag "\"abc123\"")
       (let ((result (,function-name *test-client* ,@params)))
         (true result)))
     
     ;; Test 304 Not Modified response
     (with-mock-esi-response (304 "" :etag "\"abc123\"")
       (true (,function-name *test-client* ,@params)))))

;;; Test Data Generators

(defun generate-test-character-data (&key (character-id *test-character-id*) 
                                         (name "Test Character")
                                         (corporation-id *test-corporation-id*)
                                         (alliance-id *test-alliance-id*))
  "Generate test character data"
  (format nil "{\"character_id\": ~D, \"name\": \"~A\", \"corporation_id\": ~D, \"alliance_id\": ~D, \"birthday\": \"2003-05-06T00:00:00Z\", \"bloodline_id\": 4, \"gender\": \"male\", \"race_id\": 1, \"security_status\": 5.0}"
          character-id name corporation-id alliance-id))

(defun generate-test-corporation-data (&key (corporation-id *test-corporation-id*)
                                           (name "Test Corporation")
                                           (ticker "TESTC")
                                           (alliance-id *test-alliance-id*))
  "Generate test corporation data"
  (format nil "{\"corporation_id\": ~D, \"name\": \"~A\", \"ticker\": \"~A\", \"alliance_id\": ~D, \"ceo_id\": ~D, \"member_count\": 42, \"tax_rate\": 0.1}"
          corporation-id name ticker alliance-id *test-character-id*))

(defun generate-test-alliance-data (&key (alliance-id *test-alliance-id*)
                                        (name "Test Alliance")
                                        (ticker "TEST"))
  "Generate test alliance data"
  (format nil "{\"alliance_id\": ~D, \"name\": \"~A\", \"ticker\": \"~A\", \"creator_corporation_id\": ~D, \"executor_corporation_id\": ~D}"
          alliance-id name ticker *test-corporation-id* *test-corporation-id*))

;;; Assertion Helpers

(defun is-valid-esi-response (response)
  "Check if response is a valid ESI response structure"
  (and (typep response 'esi-response)
       (esi-response-status response)
       (esi-response-body response)))

(defun is-valid-json (data)
  "Check if data is valid JSON structure"
  (or (hash-table-p data)
      (listp data)
      (stringp data)
      (numberp data)
      (member data '(t nil))))

(defun is-valid-character-id (id)
  "Check if ID is a valid character ID"
  (and (integerp id)
       (> id 0)
       (<= id 2147483647)))

(defun is-valid-corporation-id (id)
  "Check if ID is a valid corporation ID"
  (and (integerp id)
       (> id 0)
       (<= id 2147483647)))

(defun is-valid-alliance-id (id)
  "Check if ID is a valid alliance ID"
  (and (integerp id)
       (> id 0)
       (<= id 2147483647)))

(defun is-positive-number (n)
  "Check if n is a positive number"
  (and (numberp n) (> n 0)))

(defun is-iso8601-timestamp (timestamp)
  "Check if timestamp is a valid ISO8601 string"
  (and (stringp timestamp)
       (> (length timestamp) 10)
       (find #\T timestamp)
       (find #\Z timestamp)))

;;; Test Coverage Reporting

(defun test-coverage-report ()
  "Generate a test coverage report for all API endpoints"
  (let ((total-endpoints 195)
        (tested-endpoints 0)
        (missing-tests '()))
    
    ;; This would iterate through the endpoint registry and check for tests
    ;; For now, return a placeholder report
    
    (format t "~%=== Eve-Gate Test Coverage Report ===~%")
    (format t "Total API endpoints: ~D~%" total-endpoints)
    (format t "Tested endpoints: ~D~%" tested-endpoints)
    (format t "Coverage percentage: ~,1F%~%" (* 100 (/ tested-endpoints total-endpoints)))
    
    (when missing-tests
      (format t "~%Missing test coverage for:~%")
      (dolist (endpoint missing-tests)
        (format t "  - ~A~%" endpoint)))
    
    (values tested-endpoints total-endpoints missing-tests)))

(defun endpoint-test-status (operation-id)
  "Check if an endpoint has test coverage"
  ;; This would check if tests exist for the given operation ID
  ;; For now, return a placeholder
  (declare (ignore operation-id))
  :unknown)

(defun missing-test-coverage ()
  "Return list of endpoints missing test coverage"
  ;; This would analyze the endpoint registry and test files
  ;; For now, return empty list
  '())

;;; Test Suite Utilities

(defmacro define-endpoint-test-suite (suite-name endpoints &key (parent nil))
  "Define a test suite for a group of endpoints"
  `(define-test ,suite-name
     ,@(when parent `(:parent ,parent))
     ,(format nil "Test suite for ~A endpoints" (string-downcase (symbol-name suite-name)))
     
     ,@(mapcar (lambda (endpoint)
                 `(,(intern (format nil "TEST-~A" (string-upcase endpoint)))))
               endpoints)))

;;; Performance Testing Utilities

(defmacro with-timing ((time-var) &body body)
  "Execute body and capture execution time"
  (let ((start-time (gensym "START-TIME")))
    `(let ((,start-time (get-internal-real-time)))
       (prog1 (progn ,@body)
         (let ((,time-var (/ (- (get-internal-real-time) ,start-time)
                            internal-time-units-per-second)))
           ,time-var)))))

(defmacro test-performance (function-name params max-time)
  "Test that a function completes within the specified time"
  `(with-timing (duration)
     (with-mock-esi-response (200 "{\"result\": \"success\"}")
       (,function-name *test-client* ,@params))
     (true (< duration ,max-time))))

;;; Global Test Configuration

(defparameter *test-configuration*
  '(:mock-responses t
    :validate-schemas t
    :test-performance t
    :test-error-conditions t
    :test-authentication t
    :test-pagination t
    :test-caching t)
  "Global test configuration options")

(defun configure-tests (&key mock-responses validate-schemas test-performance 
                            test-error-conditions test-authentication 
                            test-pagination test-caching)
  "Configure global test behavior"
  (when mock-responses
    (setf (getf *test-configuration* :mock-responses) mock-responses))
  (when validate-schemas
    (setf (getf *test-configuration* :validate-schemas) validate-schemas))
  (when test-performance
    (setf (getf *test-configuration* :test-performance) test-performance))
  (when test-error-conditions
    (setf (getf *test-configuration* :test-error-conditions) test-error-conditions))
  (when test-authentication
    (setf (getf *test-configuration* :test-authentication) test-authentication))
  (when test-pagination
    (setf (getf *test-configuration* :test-pagination) test-pagination))
  (when test-caching
    (setf (getf *test-configuration* :test-caching) test-caching)))

;;; Test Execution Utilities

(defun run-all-api-tests (&key (report :plain) (verbose nil))
  "Run all API tests with specified reporting options"
  (parachute:test 'eve-gate-tests.generated-api:test-generated-api 
                  :report report 
                  :verbose verbose))

(defun run-category-tests (category &key (report :plain) (verbose nil))
  "Run tests for a specific API category"
  (let ((test-name (intern (format nil "TEST-~A-API" (string-upcase category))
                          'eve-gate-tests.generated-api)))
    (parachute:test test-name :report report :verbose verbose)))