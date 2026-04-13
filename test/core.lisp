;;;; test/core.lisp - Core system tests for eve-gate
;;;;
;;;; Tests for HTTP client, middleware, error handling, and conditions

(uiop:define-package #:eve-gate/test/core
  (:use #:cl)
  (:import-from #:eve-gate.core
                ;; Conditions
                #:esi-error
                #:esi-error-status-code
                #:esi-error-message
                #:esi-client-error
                #:esi-server-error
                #:esi-rate-limit-exceeded
                #:esi-rate-limit-retry-after
                #:esi-unauthorized
                #:esi-forbidden
                #:esi-not-found
                #:esi-network-error
                ;; Middleware
                #:make-middleware
                #:middleware-name
                #:middleware-priority
                #:middleware-enabled-p
                #:make-middleware-stack
                #:add-middleware
                #:apply-request-middleware
                #:apply-response-middleware)
  (:local-nicknames (#:t #:parachute)))

(in-package #:eve-gate/test/core)

;;; Condition Tests

(t:define-test esi-error-creation
  "Test ESI error condition creation and accessors"
  (let ((err (make-condition 'esi-error
                             :status-code 404
                             :message "Character not found")))
    (t:true (typep err 'esi-error))
    (t:true (typep err 'error))
    (t:is = 404 (esi-error-status-code err))
    (t:is string= "Character not found" (esi-error-message err))))

(t:define-test error-hierarchy
  "Test that error types form proper hierarchy"
  (t:true (subtypep 'esi-client-error 'esi-error))
  (t:true (subtypep 'esi-server-error 'esi-error))
  (t:true (subtypep 'esi-rate-limit-exceeded 'esi-client-error))
  (t:true (subtypep 'esi-unauthorized 'esi-client-error))
  (t:true (subtypep 'esi-forbidden 'esi-client-error))
  (t:true (subtypep 'esi-not-found 'esi-client-error))
  (t:true (subtypep 'esi-network-error 'esi-error)))

(t:define-test rate-limit-error
  "Test rate limit error creation"
  (let ((err (make-condition 'esi-rate-limit-exceeded
                             :status-code 420
                             :message "Error limited"
                             :retry-after 60)))
    (t:true (typep err 'esi-rate-limit-exceeded))
    (t:true (typep err 'esi-client-error))
    (t:true (typep err 'esi-error))
    (t:is = 420 (esi-error-status-code err))
    (t:is = 60 (esi-rate-limit-retry-after err))))

(t:define-test unauthorized-error
  "Test unauthorized error creation"
  (let ((err (make-condition 'esi-unauthorized
                             :message "Token expired")))
    (t:true (typep err 'esi-unauthorized))
    (t:true (typep err 'esi-client-error))
    (t:is = 401 (esi-error-status-code err))))

;;; Middleware Tests

(t:define-test middleware-creation
  "Test middleware struct creation"
  (let ((mw (make-middleware :name :test-mw
                             :priority 50
                             :request-fn (lambda (ctx) ctx)
                             :response-fn (lambda (resp ctx) 
                                           (declare (ignore ctx))
                                           resp))))
    (t:true mw)
    (t:is eq :test-mw (middleware-name mw))
    (t:is = 50 (middleware-priority mw))
    (t:true (middleware-enabled-p mw))))

(t:define-test middleware-priority-ordering
  "Test that middleware priorities order correctly"
  (let ((mw-high (make-middleware :name :high :priority 100
                                  :request-fn (lambda (ctx) ctx)
                                  :response-fn (lambda (r c) (declare (ignore c)) r)))
        (mw-low (make-middleware :name :low :priority 10
                                 :request-fn (lambda (ctx) ctx)
                                 :response-fn (lambda (r c) (declare (ignore c)) r))))
    ;; Higher priority number means higher priority
    (t:true (> (middleware-priority mw-high) (middleware-priority mw-low)))))

(t:define-test middleware-stack-creation
  "Test middleware stack can be created"
  (let ((mw1 (make-middleware :name :first :priority 10
                              :request-fn (lambda (ctx) ctx)))
        (mw2 (make-middleware :name :second :priority 20
                              :request-fn (lambda (ctx) ctx))))
    (let ((stack (make-middleware-stack mw1 mw2)))
      (t:true (listp stack))
      (t:is = 2 (length stack))
      ;; Lower priority should come first
      (t:is eq :first (middleware-name (first stack))))))

(t:define-test middleware-stack-add
  "Test adding middleware to stack"
  (let* ((mw1 (make-middleware :name :first :priority 10
                               :request-fn (lambda (ctx) ctx)))
         (mw2 (make-middleware :name :second :priority 5
                               :request-fn (lambda (ctx) ctx)))
         (stack (make-middleware-stack mw1))
         (new-stack (add-middleware stack mw2)))
    (t:is = 2 (length new-stack))
    ;; mw2 has lower priority (5) so should come first
    (t:is eq :second (middleware-name (first new-stack)))))

(t:define-test middleware-request-execution
  "Test middleware processes requests"
  (let* ((call-order '())
         (mw1 (make-middleware :name :first :priority 10
                               :request-fn (lambda (ctx)
                                            (push :first call-order)
                                            ctx)))
         (mw2 (make-middleware :name :second :priority 20
                               :request-fn (lambda (ctx)
                                            (push :second call-order)
                                            ctx)))
         (stack (make-middleware-stack mw1 mw2)))
    (apply-request-middleware stack '(:method :get :path "/test"))
    ;; Lower priority (10) runs first, then higher (20)
    ;; So call-order will be (:second :first) due to push
    (t:is = 2 (length call-order))
    (t:is eq :second (first call-order))
    (t:is eq :first (second call-order))))

(t:define-test middleware-context-transformation
  "Test middleware can transform request context"
  (let* ((mw (make-middleware :name :transform :priority 10
                              :request-fn (lambda (ctx)
                                           (setf (getf ctx :transformed) t)
                                           ctx)))
         (stack (make-middleware-stack mw)))
    (let ((result (apply-request-middleware stack '(:method :get))))
      (t:true (getf result :transformed)))))
