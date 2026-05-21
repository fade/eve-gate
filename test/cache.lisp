;;;; test/cache.lisp - Cache system tests for eve-gate
;;;;
;;;; Tests for memory cache, ETag cache, and cache policies

(uiop:define-package #:eve-gate/test/cache
  (:use #:cl)
  (:import-from #:eve-gate.cache
                ;; Memory cache
                #:make-memory-cache
                #:memory-cache-get
                #:memory-cache-put
                #:memory-cache-delete
                #:memory-cache-clear
                #:memory-cache-count
                #:memory-cache-exists-p
                ;; ETag cache
                #:make-etag-cache
                #:etag-cache-get
                #:etag-cache-put
                #:etag-cache-count
                ;; Database (L2) cache
                #:make-database-cache
                #:database-cache-get
                #:database-cache-put
                #:database-cache-delete
                #:database-cache-clear
                #:database-cache-statistics
                ;; Policies
                #:make-cache-key
                #:get-cache-policy
                #:compute-ttl-from-headers
                #:*policy-standard*)
  (:local-nicknames (#:t #:parachute)
                    (#:bt #:bordeaux-threads)))

(in-package #:eve-gate/test/cache)

;;; Memory Cache Tests

(t:define-test memory-cache-creation
  "Test memory cache creation"
  (let ((cache (make-memory-cache :max-entries 100)))
    (t:true cache)
    (t:is = 0 (memory-cache-count cache))))

(t:define-test memory-cache-put-and-get
  "Test memory cache put and get operations"
  (let ((cache (make-memory-cache :max-entries 100)))
    ;; Put a value
    (memory-cache-put cache "key1" "value1")
    (t:is = 1 (memory-cache-count cache))
    
    ;; Get it back
    (let ((value (memory-cache-get cache "key1")))
      (t:is string= "value1" value))
    
    ;; Get non-existent key returns nil
    (let ((value (memory-cache-get cache "nonexistent")))
      (t:is eq nil value))))

(t:define-test memory-cache-delete
  "Test memory cache deletion"
  (let ((cache (make-memory-cache :max-entries 100)))
    (memory-cache-put cache "key1" "value1")
    (t:is = 1 (memory-cache-count cache))
    
    (memory-cache-delete cache "key1")
    (t:is = 0 (memory-cache-count cache))
    
    (let ((value (memory-cache-get cache "key1")))
      (t:is eq nil value))))

(t:define-test memory-cache-clear
  "Test memory cache clearing"
  (let ((cache (make-memory-cache :max-entries 100)))
    (memory-cache-put cache "key1" "value1")
    (memory-cache-put cache "key2" "value2")
    (memory-cache-put cache "key3" "value3")
    (t:is = 3 (memory-cache-count cache))
    
    (memory-cache-clear cache)
    (t:is = 0 (memory-cache-count cache))))

(t:define-test memory-cache-exists-p
  "Test memory cache exists-p"
  (let ((cache (make-memory-cache :max-entries 100)))
    (memory-cache-put cache "key1" "value1")
    (t:true (memory-cache-exists-p cache "key1"))
    (t:false (memory-cache-exists-p cache "nonexistent"))))

(t:define-test memory-cache-eviction
  "Test memory cache LRU eviction"
  (let ((cache (make-memory-cache :max-entries 3)))
    ;; Fill the cache
    (memory-cache-put cache "key1" "value1")
    (memory-cache-put cache "key2" "value2")
    (memory-cache-put cache "key3" "value3")
    (t:is = 3 (memory-cache-count cache))
    
    ;; Add one more - should evict oldest
    (memory-cache-put cache "key4" "value4")
    (t:is = 3 (memory-cache-count cache))
    
    ;; key1 should be evicted (LRU)
    (t:false (memory-cache-exists-p cache "key1"))
    
    ;; key4 should exist
    (let ((value (memory-cache-get cache "key4")))
      (t:is string= "value4" value))))

;;; ETag Cache Tests

(t:define-test etag-cache-creation
  "Test ETag cache creation"
  (let ((cache (make-etag-cache :max-entries 1000)))
    (t:true cache)))

(t:define-test etag-cache-put-and-get
  "Test ETag cache put and get operations"
  (let ((cache (make-etag-cache :max-entries 1000)))
    ;; Store an ETag
    (etag-cache-put cache "/characters/123/" "\"abc123\"")
    
    ;; Retrieve it
    (let ((entry (etag-cache-get cache "/characters/123/")))
      (t:true entry))
    
    ;; Non-existent key returns nil
    (let ((entry (etag-cache-get cache "/nonexistent/")))
      (t:is eq nil entry))))

;;; Cache Key Tests

(t:define-test cache-key-generation
  "Test cache key generation"
  (let ((key1 (make-cache-key "/characters/123/"))
        (key2 (make-cache-key "/characters/123/" 
                              :params '(("datasource" . "tranquility"))))
        (key3 (make-cache-key "/characters/456/")))
    ;; Keys should be strings
    (t:true (stringp key1))
    (t:true (stringp key2))
    (t:true (stringp key3))
    
    ;; Same endpoint with different params should have different keys
    (t:isnt string= key1 key2)
    
    ;; Different endpoints should have different keys
    (t:isnt string= key1 key3)))

(t:define-test cache-key-deterministic
  "Test that cache key generation is deterministic"
  (let ((key1 (make-cache-key "/test/" :params '(("a" . "1") ("b" . "2"))))
        (key2 (make-cache-key "/test/" :params '(("a" . "1") ("b" . "2")))))
    (t:is string= key1 key2)))

;;; Cache Policy Tests

(t:define-test standard-cache-policy-exists
  "Test that standard cache policy exists"
  (t:true *policy-standard*))

(t:define-test compute-ttl-from-headers-function
  "Test TTL computation from cache headers"
  ;; With max-age header
  (let ((ttl (compute-ttl-from-headers 
              '(("cache-control" . "max-age=300")))))
    (t:true (numberp ttl)))
  
  ;; With expires header (returns a value)
  (let ((ttl (compute-ttl-from-headers nil)))
    ;; nil headers returns default TTL
    (t:true (or (null ttl) (numberp ttl)))))

(t:define-test get-endpoint-cache-policy-function
  "Test getting cache policy for endpoints"
  ;; Status endpoint should have a policy
  (let ((policy (get-cache-policy "/status/")))
    (t:true policy))

  ;; Universe endpoints should have a policy
  (let ((policy (get-cache-policy "/universe/types/")))
    (t:true policy)))

;;; Database (L2) Cache Tests
;;;
;;; The L2 file-based cache is shared by every thread that touches the
;;; cache manager — in eve-quant's heat-map driver that's 8 scheduler
;;; workers plus a driver thread plus a retry-scheduler, all banging on
;;; the same database-cache concurrently. These tests cover the basic
;;; per-key contract and exercise the unlocked concurrent paths so a
;;; future regression that re-introduces a serializing lock around
;;; get/put/delete shows up as a wall-clock blowout instead of a silent
;;; production tax.

(defun %tmp-cache-dir (label)
  "Return a per-test scratch directory under TMPDIR."
  (let ((root (merge-pathnames
               (make-pathname :directory (list :relative
                                               (format nil "eve-gate-test-~A-~A"
                                                       label
                                                       (get-internal-real-time))))
               (uiop:temporary-directory))))
    (ensure-directories-exist root)
    root))

(t:define-test database-cache-put-and-get
  "Round-trip a value through the L2 cache."
  (let* ((dir (%tmp-cache-dir "rt"))
         (cache (make-database-cache :directory dir)))
    (unwind-protect
         (progn
           (t:true (database-cache-put cache "k1" "v1" :ttl 60))
           (multiple-value-bind (value etag) (database-cache-get cache "k1")
             (t:is string= "v1" value)
             (t:is eq nil etag))
           ;; Missing key returns NIL/NIL and bumps :misses.
           (multiple-value-bind (value etag) (database-cache-get cache "nope")
             (t:is eq nil value)
             (t:is eq nil etag))
           (let ((stats (database-cache-statistics cache)))
             (t:is = 1 (getf stats :hits))
             (t:is = 1 (getf stats :misses))
             (t:is = 1 (getf stats :puts))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(t:define-test database-cache-delete-is-idempotent
  "Delete is a no-op when the key is absent; valid delete bumps :deletes."
  (let* ((dir (%tmp-cache-dir "del"))
         (cache (make-database-cache :directory dir)))
    (unwind-protect
         (progn
           (database-cache-put cache "k" "v" :ttl 60)
           (t:true (database-cache-delete cache "k"))
           (t:is eq nil (database-cache-get cache "k"))
           ;; Second delete on the same key returns NIL without erroring.
           (t:is eq nil (database-cache-delete cache "k"))
           (let ((stats (database-cache-statistics cache)))
             (t:is = 1 (getf stats :deletes))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(t:define-test database-cache-concurrent-disjoint-keys
  "8 threads each owning a disjoint key range run to completion with no
errors, every put is observable to its own thread, and the recorded
:puts / :hits counts equal the work performed.  This is the regression
test for the L2 lock-contention blowout: with the lock in place this
test would still pass functionally — the assertion that matters here
is that the run completes inside a generous wall-clock budget without
producing any read or write errors, since contention manifested as
hour-scale stalls under production load."
  (let* ((dir (%tmp-cache-dir "concurrent"))
         (cache (make-database-cache :directory dir))
         (threads 8)
         (ops-per-thread 200)
         (errors 0)
         (errors-lock (bt:make-lock "concurrent-test-errors")))
    (unwind-protect
         (let ((started (get-internal-real-time))
               (workers
                 (loop for tid below threads
                       collect (bt:make-thread
                                (let ((tid tid))
                                  (lambda ()
                                    (handler-case
                                        (loop for i below ops-per-thread
                                              for key = (format nil "t~D-k~D" tid i)
                                              for value = (format nil "t~D-v~D" tid i)
                                              do (database-cache-put cache key value
                                                                     :ttl 60)
                                                 (let ((got (database-cache-get cache key)))
                                                   (unless (equal got value)
                                                     (bt:with-lock-held (errors-lock)
                                                       (incf errors)))))
                                      (error ()
                                        (bt:with-lock-held (errors-lock)
                                          (incf errors))))))
                                :name (format nil "db-cache-worker-~D" tid)))))
           (dolist (w workers) (bt:join-thread w))
           (let ((elapsed-s (/ (- (get-internal-real-time) started)
                               (coerce internal-time-units-per-second 'float))))
             (t:is = 0 errors)
             (let ((stats (database-cache-statistics cache)))
               (t:is = (* threads ops-per-thread) (getf stats :puts))
               (t:is = (* threads ops-per-thread) (getf stats :hits)))
             ;; 8 threads × 200 ops = 1600 round-trips.  With the
             ;; serializing lock removed this completes in well under a
             ;; second on commodity hardware; allow 30s so slow CI
             ;; spindles don't false-alarm but a real regression
             ;; (serialized IO across threads) still trips.
             (t:true (< elapsed-s 30.0))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(t:define-test database-cache-concurrent-shared-key
  "Multiple threads writing the same key concurrently must produce
exactly one valid file at the end (atomic temp-file rename), no error
counters bumped, and the final read returns one of the written
values.  Exercises that put-against-put on a shared key is safe
without a serializing lock."
  (let* ((dir (%tmp-cache-dir "shared"))
         (cache (make-database-cache :directory dir))
         (threads 8)
         (writes-per-thread 100)
         (key "shared-key"))
    (unwind-protect
         (let ((workers
                 (loop for tid below threads
                       collect (bt:make-thread
                                (let ((tid tid))
                                  (lambda ()
                                    (loop for i below writes-per-thread
                                          do (database-cache-put
                                              cache key
                                              (format nil "t~D-w~D" tid i)
                                              :ttl 60))))
                                :name (format nil "db-cache-shared-~D" tid)))))
           (dolist (w workers) (bt:join-thread w))
           (let ((final (database-cache-get cache key))
                 (stats (database-cache-statistics cache)))
             ;; Final value is well-formed (one of the writes won).
             (t:true (stringp final))
             ;; No deserialization errors from a half-written file.
             (t:is = 0 (getf stats :errors))
             (t:is = (* threads writes-per-thread)
                   (getf stats :puts))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))
