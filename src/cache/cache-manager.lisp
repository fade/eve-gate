;;;; cache-manager.lisp - Central cache coordination for eve-gate
;;;;
;;;; The cache manager is the single point of coordination for all caching
;;;; operations in eve-gate. It orchestrates the two-tier cache hierarchy
;;;; (L1 memory + L2 persistent), ETag-based conditional requests, cache
;;;; policies, and invalidation.
;;;;
;;;; Cache lookup flow (for a GET request):
;;;;   1. Generate cache key from endpoint, params, auth context
;;;;   2. Check L1 memory cache → if hit, return immediately
;;;;   3. Check L2 database cache → if hit, promote to L1 and return
;;;;   4. Check ETag cache → if we have an ETag, make conditional request
;;;;   5. Make full request, cache the response in L1 (and L2 per policy)
;;;;
;;;; Write invalidation flow (for POST/PUT/DELETE):
;;;;   1. Execute the write request
;;;;   2. Look up invalidation targets from the policy rules
;;;;   3. Remove affected entries from L1 and L2 caches
;;;;
;;;; The cache manager also provides:
;;;;   - Middleware integration for transparent caching
;;;;   - Comprehensive cache statistics
;;;;   - Manual cache invalidation and management
;;;;   - Configuration for per-endpoint caching behavior
;;;;
;;;; Design: The cache manager is a mutable struct that holds references to
;;;; the cache tiers and policies. It is thread-safe through the individual
;;;; tier locks. The manager itself has a lock only for configuration changes.

(in-package #:eve-gate.cache)

;;; ---------------------------------------------------------------------------
;;; Cache manager structure
;;; ---------------------------------------------------------------------------

(defstruct (cache-manager (:constructor %make-cache-manager))
  "Central cache coordination and policy enforcement.

Orchestrates the two-tier cache hierarchy:
  L1: In-memory LRU cache (fast, bounded)
  L2: Persistent file-based cache (slower, survives restarts)
  ETag: Lightweight ETag tracker (for conditional requests)

Slots:
  MEMORY-CACHE: L1 in-memory cache
  DATABASE-CACHE: L2 persistent cache
  ETAG-CACHE: ETag tracking cache
  ENABLED-P: Master switch for all caching
  LOCK: Lock for configuration changes
  GLOBAL-STATS: Aggregated statistics
  DEFAULT-DATASOURCE: Default datasource for cache key generation"
  (memory-cache nil :type (or null memory-cache))
  (database-cache nil :type (or null database-cache))
  (etag-cache nil :type (or null etag-cache))
  (enabled-p t :type boolean)
  (lock (bt:make-lock "cache-manager-lock"))
  (global-stats (list :requests 0 :l1-hits 0 :l2-hits 0 :etag-hits 0
                       :full-fetches 0 :invalidations 0 :bypasses 0)
                :type list)
  (default-datasource "tranquility" :type string))

(defun make-cache-manager (&key (memory-cache-size 10000)
                                 (etag-cache-size 50000)
                                 (database-cache-enabled nil)
                                 (database-cache-directory *database-cache-directory*)
                                 (database-cache-max-age (* 7 24 60 60))
                                 (enabled t)
                                 (datasource "tranquility"))
  "Create a new cache manager with the specified configuration.

MEMORY-CACHE-SIZE: Max entries in L1 memory cache (default: 10000)
ETAG-CACHE-SIZE: Max entries in ETag cache (default: 50000)
DATABASE-CACHE-ENABLED: Enable L2 persistent cache (default: NIL)
DATABASE-CACHE-DIRECTORY: L2 cache directory (default: ~/.cache/eve-gate/)
DATABASE-CACHE-MAX-AGE: Max age for L2 entries in seconds (default: 7 days)
ENABLED: Master caching switch (default: T)
DATASOURCE: Default datasource for cache keys (default: \"tranquility\")

Returns a CACHE-MANAGER struct.

Example:
  ;; Basic cache manager with memory-only caching
  (make-cache-manager)

  ;; Full two-tier cache with persistence
  (make-cache-manager :database-cache-enabled t
                      :memory-cache-size 20000)"
  (%make-cache-manager
   :memory-cache (make-memory-cache :max-entries memory-cache-size)
   :database-cache (make-database-cache :directory database-cache-directory
                                         :enabled database-cache-enabled
                                         :max-age database-cache-max-age)
   :etag-cache (make-etag-cache :max-entries etag-cache-size)
   :enabled-p enabled
   :default-datasource datasource))

;;; ---------------------------------------------------------------------------
;;; Core cache operations
;;; ---------------------------------------------------------------------------

(defun cache-get (manager key &key operation-id)
  "Look up a cached value using the two-tier hierarchy.

Checks L1 memory first, then L2 database. On L2 hit, promotes to L1.

MANAGER: A cache-manager struct
KEY: Cache key string
OPERATION-ID: Optional operation ID for policy lookup

Returns three values:
  1. The cached value, or NIL
  2. The ETag for this key (even if data is expired/missing)
  3. Cache tier that served the data (:l1, :l2, or NIL)

Thread-safe."
  (unless (cache-manager-enabled-p manager)
    (bt:with-lock-held ((cache-manager-lock manager))
      (incf (getf (cache-manager-global-stats manager) :bypasses)))
    (return-from cache-get (values nil nil nil)))

  (bt:with-lock-held ((cache-manager-lock manager))
    (incf (getf (cache-manager-global-stats manager) :requests)))

  ;; 1. Check L1 memory cache
  (multiple-value-bind (value entry)
      (memory-cache-get (cache-manager-memory-cache manager) key)
    (when value
      (bt:with-lock-held ((cache-manager-lock manager))
        (incf (getf (cache-manager-global-stats manager) :l1-hits)))
      (return-from cache-get
        (values value
                (when entry (cache-entry-etag entry))
                :l1))))

  ;; 2. Check L2 database cache
  (when (database-cache-enabled-p (cache-manager-database-cache manager))
    (multiple-value-bind (value etag)
        (database-cache-get (cache-manager-database-cache manager) key)
      (when value
        ;; Promote to L1
        (let ((policy (if operation-id
                          (get-cache-policy operation-id)
                          *policy-standard*)))
          (memory-cache-put (cache-manager-memory-cache manager) key value
                            :etag etag
                            :ttl (cache-policy-ttl policy)))
        (bt:with-lock-held ((cache-manager-lock manager))
          (incf (getf (cache-manager-global-stats manager) :l2-hits)))
        (return-from cache-get (values value etag :l2)))))

  ;; 3. No data found - return any cached ETag for conditional requests
  (let ((etag (etag-cache-get (cache-manager-etag-cache manager) key)))
    ;; Also check if memory cache has an expired entry with an ETag
    (unless etag
      (multiple-value-bind (val expired-entry)
          (memory-cache-get (cache-manager-memory-cache manager) key)
        (declare (ignore val))
        (when expired-entry
          (setf etag (cache-entry-etag expired-entry)))))
    (values nil etag nil)))

(defun cache-put (manager key value &key etag operation-id category headers)
  "Store a value in the cache hierarchy according to the endpoint's policy.

MANAGER: A cache-manager struct
KEY: Cache key string
VALUE: The data to cache
ETAG: ETag from the ESI response
OPERATION-ID: Operation ID for policy lookup
CATEGORY: Endpoint category for policy fallback
HEADERS: Response headers for TTL computation

Thread-safe."
  (unless (cache-manager-enabled-p manager)
    (return-from cache-put nil))

  (let* ((policy (get-cache-policy (or operation-id "") category))
         (ttl (if headers
                  (compute-ttl-from-headers headers (cache-policy-ttl policy))
                  (cache-policy-ttl policy))))
    ;; Store in L1 memory cache if policy allows
    (when (cache-policy-cache-in-memory-p policy)
      (memory-cache-put (cache-manager-memory-cache manager) key value
                        :etag etag
                        :ttl ttl))

    ;; Store in L2 database cache if policy allows
    (when (and (cache-policy-cache-in-db-p policy)
               (database-cache-enabled-p (cache-manager-database-cache manager)))
      (database-cache-put (cache-manager-database-cache manager) key value
                          :etag etag
                          :ttl ttl))

    ;; Always store the ETag
    (when etag
      (etag-cache-put (cache-manager-etag-cache manager) key etag)))
  value)

(defun cache-delete (manager key)
  "Remove a cached value from all tiers.

MANAGER: A cache-manager struct
KEY: Cache key string

Thread-safe."
  (memory-cache-delete (cache-manager-memory-cache manager) key)
  (when (database-cache-enabled-p (cache-manager-database-cache manager))
    (database-cache-delete (cache-manager-database-cache manager) key))
  (etag-cache-delete (cache-manager-etag-cache manager) key)
  (bt:with-lock-held ((cache-manager-lock manager))
    (incf (getf (cache-manager-global-stats manager) :invalidations))))

(defun cache-exists-p (manager key)
  "Check if KEY exists (and is not expired) in any cache tier.

MANAGER: A cache-manager struct
KEY: Cache key string

Returns T if a valid entry exists in L1 or L2.

Thread-safe."
  (or (memory-cache-exists-p (cache-manager-memory-cache manager) key)
      (and (database-cache-enabled-p (cache-manager-database-cache manager))
           (database-cache-exists-p (cache-manager-database-cache manager) key))))

(defun cache-clear (manager)
  "Clear all cache tiers.

MANAGER: A cache-manager struct

Thread-safe."
  (memory-cache-clear (cache-manager-memory-cache manager))
  (when (database-cache-enabled-p (cache-manager-database-cache manager))
    (database-cache-clear (cache-manager-database-cache manager)))
  (etag-cache-clear (cache-manager-etag-cache manager))
  (bt:with-lock-held ((cache-manager-lock manager))
    (setf (cache-manager-global-stats manager)
          (list :requests 0 :l1-hits 0 :l2-hits 0 :etag-hits 0
                :full-fetches 0 :invalidations 0 :bypasses 0))))

;;; ---------------------------------------------------------------------------
;;; Write invalidation
;;; ---------------------------------------------------------------------------

(defun invalidate-for-write (manager write-operation-id &key auth-context)
  "Invalidate cached data affected by a write operation.

When a POST/PUT/DELETE is made, this function removes cached GET data
that may have been invalidated by the write.

MANAGER: A cache-manager struct
WRITE-OPERATION-ID: Operation ID of the write endpoint
AUTH-CONTEXT: Authentication context (character/corp ID) to scope invalidation

Thread-safe."
  (let ((targets (get-invalidation-targets write-operation-id)))
    (when targets
      (log-debug "Cache invalidation for ~A: ~D targets"
                 write-operation-id (length targets))
      ;; For each target, we need to invalidate matching cache keys.
      ;; Since we can't enumerate all possible parameter combinations,
      ;; we invalidate based on key prefix matching.
      (dolist (target-op targets)
        (invalidate-by-operation manager target-op :auth-context auth-context)))))

(defun invalidate-by-operation (manager operation-id &key auth-context)
  "Invalidate all cached entries for a specific operation ID.

This performs a scan of the memory cache to find and remove entries
whose keys match the operation's endpoint path.

MANAGER: A cache-manager struct
OPERATION-ID: The operation ID to invalidate
AUTH-CONTEXT: Optional auth context to scope invalidation

Thread-safe."
  (let* ((meta (when (fboundp 'eve-gate.api:find-endpoint)
                 (funcall 'eve-gate.api:find-endpoint operation-id)))
         (path (when meta (getf meta :path))))
    (when path
      ;; Invalidate all memory cache keys that contain this path
      (let ((keys (memory-cache-keys (cache-manager-memory-cache manager))))
        (dolist (key keys)
          (when (and (search path key)
                     ;; If auth-context provided, only invalidate matching entries
                     (or (null auth-context)
                         (search auth-context key)))
            (cache-delete manager key)))))))

;;; ---------------------------------------------------------------------------
;;; High-level caching interface
;;; ---------------------------------------------------------------------------

(defun cache-lookup (manager endpoint &key params auth-context datasource
                                           operation-id category)
  "High-level cache lookup that generates the cache key and looks up the value.

MANAGER: A cache-manager struct
ENDPOINT: ESI endpoint path
PARAMS: Query parameters alist
AUTH-CONTEXT: Authentication context string
DATASOURCE: Datasource string
OPERATION-ID: Operation ID for policy lookup
CATEGORY: Endpoint category (used for policy fallback)

Returns three values: value, etag, cache-tier."
  (declare (ignore category))
  (let ((key (make-cache-key endpoint
                             :params params
                             :auth-context auth-context
                             :datasource (or datasource
                                             (cache-manager-default-datasource manager)))))
    (cache-get manager key :operation-id operation-id)))

(defun cache-store (manager endpoint value &key params auth-context datasource
                                                etag operation-id category headers)
  "High-level cache store that generates the cache key and stores the value.

MANAGER: A cache-manager struct
ENDPOINT: ESI endpoint path
VALUE: The data to cache
PARAMS: Query parameters alist
AUTH-CONTEXT: Authentication context string
DATASOURCE: Datasource string
ETAG: ETag from ESI response
OPERATION-ID: Operation ID for policy lookup
CATEGORY: Endpoint category
HEADERS: Response headers for TTL computation"
  (let ((key (make-cache-key endpoint
                             :params params
                             :auth-context auth-context
                             :datasource (or datasource
                                             (cache-manager-default-datasource manager)))))
    (cache-put manager key value
               :etag etag
               :operation-id operation-id
               :category category
               :headers headers)))

;;; ---------------------------------------------------------------------------
;;; Cache middleware for HTTP pipeline
;;; ---------------------------------------------------------------------------

(defun make-cache-middleware (manager)
  "Create a middleware component that transparently caches ESI responses.

This middleware:
  - On request: checks the cache and returns cached data if available.
    Adds If-None-Match header with cached ETag for conditional requests.
  - On response: caches the response data according to endpoint policy.
    Handles 304 Not Modified by returning cached data.

MANAGER: A cache-manager struct

Returns a middleware struct suitable for the HTTP client pipeline.

Example:
  (add-middleware (http-client-middleware-stack client)
                  (make-cache-middleware manager))"
  (make-middleware
   :name :cache
   :priority 50  ; after headers/auth, before logging/error
   :request-fn
   (lambda (ctx)
     (if (cache-manager-enabled-p manager)
         (%cache-request-middleware manager ctx)
         ctx))
   :response-fn
   (lambda (response ctx)
     (if (cache-manager-enabled-p manager)
         (%cache-response-middleware manager response ctx)
         response))))

(defun %cache-request-middleware (manager ctx)
  "Request-phase cache middleware.
Checks cache for GET requests and adds ETag headers for conditional requests.

Internal: called by the cache middleware."
  (let* ((method (getf ctx :method))
         (path (getf ctx :path))
         (operation-id (getf ctx :operation-id)))
    ;; Only cache GET requests
    (unless (eq method :get)
      (return-from %cache-request-middleware ctx))

    ;; Check if this endpoint is cacheable
    (when (and operation-id
               (not (cacheable-request-p method operation-id)))
      (return-from %cache-request-middleware ctx))

    ;; Generate cache key
    (let* ((params (getf ctx :query-params))
           (auth-context (extract-auth-context-from-params params))
           (key (make-cache-key (or path "")
                                :params params
                                :auth-context auth-context
                                :datasource (cache-manager-default-datasource manager))))

      ;; Store key in context for response middleware to use
      (setf (getf ctx :cache-key) key
            (getf ctx :cache-auth-context) auth-context)

      ;; Check L1 and L2 caches
      (multiple-value-bind (value etag tier)
          (cache-get manager key :operation-id operation-id)
        (cond
          ;; Cache hit - store value for response middleware to return
          (value
           (setf (getf ctx :cache-hit) t
                 (getf ctx :cache-value) value
                 (getf ctx :cache-tier) tier)
           (log-debug "Cache ~A hit for ~A" tier path))

          ;; No cache hit, but we have an ETag - add conditional header
          (etag
           (let ((headers (getf ctx :headers)))
             (setf (getf ctx :headers)
                   (cons (cons "If-None-Match" etag) headers))
             (setf (getf ctx :cache-etag) etag))
           (log-debug "Conditional request with ETag for ~A" path))))))
  ctx)

(defun %cache-response-middleware (manager response ctx)
  "Response-phase cache middleware.
Caches successful responses and handles 304 Not Modified.

Internal: called by the cache middleware."
  ;; If we had a cache hit in request phase, create a synthetic response
  (when (getf ctx :cache-hit)
    (return-from %cache-response-middleware
      (make-esi-response
       :status 200
       :body (getf ctx :cache-value)
       :headers (esi-response-headers response)
       :cached-p t)))

  (let* ((method (getf ctx :method))
         (status (esi-response-status response))
         (key (getf ctx :cache-key))
         (operation-id (getf ctx :operation-id))
         (category (getf ctx :category))
         (auth-context (getf ctx :cache-auth-context)))

    ;; Handle 304 Not Modified
    (when (and (= status 304) key)
      (let ((etag (getf ctx :cache-etag)))
        (when etag
          (etag-cache-record-result (cache-manager-etag-cache manager) key 304))
        ;; Try to serve from L2 cache (L1 was already checked)
        (multiple-value-bind (value stored-etag)
            (when (database-cache-enabled-p (cache-manager-database-cache manager))
              (database-cache-get (cache-manager-database-cache manager) key))
          (when value
            (bt:with-lock-held ((cache-manager-lock manager))
              (incf (getf (cache-manager-global-stats manager) :etag-hits)))
            (return-from %cache-response-middleware
              (make-esi-response
               :status 200
               :body value
               :headers (esi-response-headers response)
               :etag (or stored-etag etag)
               :cached-p t))))))

    ;; Cache successful GET responses
    (when (and (eq method :get)
               key
               (<= 200 status 299)
               (esi-response-body response))
      (let ((etag (esi-response-etag response))
            (headers (esi-response-headers response)))
        (cache-put manager key (esi-response-body response)
                   :etag etag
                   :operation-id operation-id
                   :category category
                   :headers headers)
        ;; Record ETag result for conditional requests
        (when (and etag (getf ctx :cache-etag))
          (etag-cache-record-result (cache-manager-etag-cache manager) key 200))
        (bt:with-lock-held ((cache-manager-lock manager))
          (incf (getf (cache-manager-global-stats manager) :full-fetches)))))

    ;; Handle write invalidation for POST/PUT/DELETE
    (when (and (member method '(:post :put :delete))
               operation-id
               (<= 200 status 299))
      (invalidate-for-write manager operation-id :auth-context auth-context)))

  response)

;;; ---------------------------------------------------------------------------
;;; WITH-CACHING macro
;;; ---------------------------------------------------------------------------

(defmacro with-caching ((manager-form &key bypass) &body body)
  "Execute BODY with caching enabled or bypassed.

MANAGER-FORM: Expression evaluating to a cache-manager struct
BYPASS: If T, temporarily disable caching for BODY
BODY: Forms to execute

Example:
  ;; Normal usage (caching enabled)
  (with-caching (manager)
    (api-get client \"/v5/characters/95465499/\"))

  ;; Bypass cache for fresh data
  (with-caching (manager :bypass t)
    (api-get client \"/v5/characters/95465499/\"))"
  (let ((mgr (gensym "MANAGER"))
        (old-enabled (gensym "OLD-ENABLED")))
    `(let* ((,mgr ,manager-form)
            (,old-enabled (cache-manager-enabled-p ,mgr)))
       (unwind-protect
            (progn
              (when ,bypass
                (setf (cache-manager-enabled-p ,mgr) nil))
              ,@body)
         (setf (cache-manager-enabled-p ,mgr) ,old-enabled)))))

;;; ---------------------------------------------------------------------------
;;; Statistics and monitoring
;;; ---------------------------------------------------------------------------

(defun cache-statistics (manager)
  "Return comprehensive cache statistics from all tiers.

MANAGER: A cache-manager struct

Returns a plist with aggregated statistics from all cache tiers.

Thread-safe."
  (bt:with-lock-held ((cache-manager-lock manager))
    (let ((global (copy-list (cache-manager-global-stats manager)))
          (memory (memory-cache-statistics (cache-manager-memory-cache manager)))
          (etag (etag-cache-statistics (cache-manager-etag-cache manager)))
          (db (database-cache-statistics (cache-manager-database-cache manager))))
      (list :global global
            :memory memory
            :etag etag
            :database db
            :enabled (cache-manager-enabled-p manager)))))

(defun cache-hit-rate (manager)
  "Return the overall cache hit rate as a float (0.0 to 1.0).

MANAGER: A cache-manager struct

Thread-safe."
  (bt:with-lock-held ((cache-manager-lock manager))
    (let* ((stats (cache-manager-global-stats manager))
           (requests (getf stats :requests))
           (hits (+ (getf stats :l1-hits)
                    (getf stats :l2-hits)
                    (getf stats :etag-hits))))
      (if (plusp requests)
          (float (/ hits requests))
          0.0))))

;;; ---------------------------------------------------------------------------
;;; Maintenance
;;; ---------------------------------------------------------------------------

(defun cache-purge-expired (manager)
  "Purge all expired entries from all cache tiers.

MANAGER: A cache-manager struct

Returns the total number of entries removed.

Thread-safe."
  (let ((count 0))
    (incf count (memory-cache-purge-expired
                 (cache-manager-memory-cache manager)))
    (when (database-cache-enabled-p (cache-manager-database-cache manager))
      (incf count (database-cache-purge-expired
                   (cache-manager-database-cache manager))))
    count))

;;; ---------------------------------------------------------------------------
;;; REPL inspection
;;; ---------------------------------------------------------------------------

(defun cache-summary (manager &optional (stream *standard-output*))
  "Print a comprehensive summary of the cache system state.

MANAGER: A cache-manager struct
STREAM: Output stream (default: *standard-output*)

Useful for REPL inspection of cache health."
  (format stream "~&Eve-Gate Cache System Summary~%")
  (format stream "~A~%" (make-string 50 :initial-element #\=))
  (format stream "Enabled: ~A  Datasource: ~A~%"
          (cache-manager-enabled-p manager)
          (cache-manager-default-datasource manager))

  ;; Global stats
  (bt:with-lock-held ((cache-manager-lock manager))
    (let ((stats (cache-manager-global-stats manager)))
      (format stream "~%Global Statistics:~%")
      (format stream "  Total requests: ~D~%" (getf stats :requests))
      (format stream "  L1 hits: ~D  L2 hits: ~D  ETag hits: ~D~%"
              (getf stats :l1-hits) (getf stats :l2-hits) (getf stats :etag-hits))
      (format stream "  Full fetches: ~D  Invalidations: ~D  Bypasses: ~D~%"
              (getf stats :full-fetches) (getf stats :invalidations) (getf stats :bypasses))
      (let ((total (getf stats :requests)))
        (when (plusp total)
          (format stream "  Overall hit rate: ~,1F%~%"
                  (* 100.0 (/ (+ (getf stats :l1-hits)
                                 (getf stats :l2-hits)
                                 (getf stats :etag-hits))
                              total)))))))

  ;; Individual tier summaries
  (format stream "~%")
  (memory-cache-summary (cache-manager-memory-cache manager) stream)
  (format stream "~%")
  (etag-cache-summary (cache-manager-etag-cache manager) stream)
  (format stream "~%")
  (database-cache-summary (cache-manager-database-cache manager) stream)
  (values))
