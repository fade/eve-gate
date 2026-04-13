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
                ;; Policies  
                #:make-cache-key
                #:get-cache-policy
                #:compute-ttl-from-headers
                #:*policy-standard*)
  (:local-nicknames (#:t #:parachute)))

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
