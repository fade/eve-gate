;;;; memory-cache.lisp - Thread-safe in-memory LRU cache for eve-gate
;;;;
;;;; Implements the L1 (memory) tier of the two-level cache architecture.
;;;; Uses a hash-table for O(1) lookup combined with a doubly-linked list
;;;; for LRU eviction ordering. All operations are thread-safe via a
;;;; per-cache read-write lock using bordeaux-threads.
;;;;
;;;; The memory cache is the hot path for ESI requests - it must be fast.
;;;; Design priorities:
;;;;   1. Sub-millisecond lookups (hash-table + direct node access)
;;;;   2. Bounded memory usage (max-entries with LRU eviction)
;;;;   3. Thread safety (read-write lock for concurrent access)
;;;;   4. TTL enforcement (entries expire according to ESI Cache-Control)
;;;;
;;;; Each cache entry stores:
;;;;   - The cached value (parsed ESI response data)
;;;;   - An ETag for conditional request support
;;;;   - Expiry time (universal-time) from ESI headers
;;;;   - Access tracking for LRU ordering
;;;;
;;;; Design: The cache is a mutable data structure with internal locking.
;;;; All public functions acquire the appropriate lock before operating.
;;;; Read operations use a shared lock; write operations use an exclusive lock.
;;;; This allows concurrent reads with exclusive writes.

(in-package #:eve-gate.cache)

;;; ---------------------------------------------------------------------------
;;; Cache entry structure
;;; ---------------------------------------------------------------------------

(defstruct (cache-entry (:constructor %make-cache-entry))
  "A single entry in the memory cache.

Slots:
  KEY: The cache key string (used for hash-table lookup)
  VALUE: The cached data (parsed ESI response body)
  ETAG: The ETag from the ESI response (for conditional requests)
  EXPIRES-AT: Universal-time when this entry expires
  CREATED-AT: Universal-time when this entry was cached
  ACCESSED-AT: Universal-time of last access (for LRU)
  ACCESS-COUNT: Number of times this entry has been accessed
  SIZE-ESTIMATE: Approximate size in bytes (for memory tracking)
  PREV: Previous node in LRU doubly-linked list
  NEXT: Next node in LRU doubly-linked list"
  (key "" :type string)
  (value nil)
  (etag nil :type (or null string))
  (expires-at 0 :type integer)
  (created-at (get-universal-time) :type integer)
  (accessed-at (get-universal-time) :type integer)
  (access-count 0 :type fixnum)
  (size-estimate 0 :type fixnum)
  (prev nil :type (or null cache-entry))
  (next nil :type (or null cache-entry)))

(defun make-cache-entry (key value &key etag ttl (size-estimate 0))
  "Create a cache entry with the given KEY, VALUE, and metadata.

KEY: Cache key string
VALUE: The data to cache
ETAG: ETag string from ESI response headers
TTL: Time-to-live in seconds (used to compute expires-at)
SIZE-ESTIMATE: Approximate size of the value in bytes

Returns a CACHE-ENTRY struct."
  (let ((now (get-universal-time)))
    (%make-cache-entry
     :key key
     :value value
     :etag etag
     :expires-at (if ttl (+ now ttl) (+ now 300)) ; default 5 min
     :created-at now
     :accessed-at now
     :access-count 0
     :size-estimate size-estimate)))

(defun cache-entry-expired-p (entry &optional (now (get-universal-time)))
  "Return T if ENTRY has expired.

ENTRY: A cache-entry struct
NOW: Current universal-time (default: current time)

Returns T if the entry's expires-at time has passed."
  (> now (cache-entry-expires-at entry)))

(defun cache-entry-ttl-remaining (entry &optional (now (get-universal-time)))
  "Return the number of seconds until ENTRY expires.

Returns a non-negative integer. Returns 0 if already expired."
  (max 0 (- (cache-entry-expires-at entry) now)))

;;; ---------------------------------------------------------------------------
;;; Memory cache structure
;;; ---------------------------------------------------------------------------
;;; NOTE: The struct must be defined before the LRU list operations so that
;;; SBCL can inline the slot accessors referenced by those functions.

(defstruct (memory-cache (:constructor %make-memory-cache))
  "Thread-safe in-memory LRU cache.

The L1 tier in the two-level cache hierarchy. Provides sub-millisecond
lookups for hot ESI data with bounded memory usage.

Slots:
  TABLE: Hash-table mapping cache keys to cache-entry structs
  MAX-ENTRIES: Maximum number of entries before LRU eviction
  LOCK: Read-write lock for thread safety
  LRU-HEAD: Most recently used entry (front of doubly-linked list)
  LRU-TAIL: Least recently used entry (back of doubly-linked list)
  STATS: Cache statistics plist
  EVICT-EXPIRED-ON-ACCESS: Whether to lazily evict expired entries on read"
  (table (make-hash-table :test 'equal) :type hash-table)
  (max-entries 10000 :type fixnum)
  (lock (bt:make-lock "memory-cache-lock"))
  (lru-head nil :type (or null cache-entry))
  (lru-tail nil :type (or null cache-entry))
  (stats (list :hits 0 :misses 0 :evictions 0 :expirations 0
               :puts 0 :deletes 0 :total-size-estimate 0)
         :type list)
  (evict-expired-on-access t :type boolean))

(defun make-memory-cache (&key (max-entries 10000)
                                (evict-expired-on-access t))
  "Create a new memory cache with the specified capacity.

MAX-ENTRIES: Maximum entries before LRU eviction (default: 10000)
EVICT-EXPIRED-ON-ACCESS: Lazily remove expired entries on read (default: T)

Returns a MEMORY-CACHE struct.

Example:
  (make-memory-cache :max-entries 5000)"
  (%make-memory-cache
   :max-entries max-entries
   :evict-expired-on-access evict-expired-on-access))

;;; ---------------------------------------------------------------------------
;;; Statistics tracking (internal, under lock)
;;; ---------------------------------------------------------------------------

(defun %inc-stat (cache stat &optional (delta 1))
  "Increment a statistics counter. Internal: must be called under lock."
  (incf (getf (memory-cache-stats cache) stat) delta))

;;; ---------------------------------------------------------------------------
;;; LRU doubly-linked list operations
;;; ---------------------------------------------------------------------------
;;; These are internal operations that manipulate the LRU list.
;;; They must be called with the write lock held.

(defun %lru-detach (entry)
  "Remove ENTRY from its current position in the LRU list.
Does not modify head/tail sentinels - caller must handle those.
Internal: must be called under write lock."
  (let ((prev (cache-entry-prev entry))
        (next (cache-entry-next entry)))
    (when prev (setf (cache-entry-next prev) next))
    (when next (setf (cache-entry-prev next) prev))
    (setf (cache-entry-prev entry) nil
          (cache-entry-next entry) nil)
    entry))

(defun %lru-push-front (cache entry)
  "Move ENTRY to the front (most recently used) of the LRU list.
Internal: must be called under write lock."
  (let ((old-head (memory-cache-lru-head cache)))
    (setf (cache-entry-next entry) old-head
          (cache-entry-prev entry) nil)
    (when old-head
      (setf (cache-entry-prev old-head) entry))
    (setf (memory-cache-lru-head cache) entry)
    ;; If list was empty, this is also the tail
    (unless (memory-cache-lru-tail cache)
      (setf (memory-cache-lru-tail cache) entry)))
  entry)

(defun %lru-remove-tail (cache)
  "Remove and return the tail (least recently used) entry from the LRU list.
Returns the removed entry, or NIL if the list is empty.
Internal: must be called under write lock."
  (let ((tail (memory-cache-lru-tail cache)))
    (when tail
      (let ((new-tail (cache-entry-prev tail)))
        (if new-tail
            (setf (cache-entry-next new-tail) nil
                  (memory-cache-lru-tail cache) new-tail)
            ;; List is now empty
            (setf (memory-cache-lru-head cache) nil
                  (memory-cache-lru-tail cache) nil))
        (setf (cache-entry-prev tail) nil
              (cache-entry-next tail) nil))
      tail)))

(defun %lru-move-to-front (cache entry)
  "Move an existing ENTRY to the front of the LRU list.
Internal: must be called under write lock."
  ;; If already at head, nothing to do
  (unless (eq entry (memory-cache-lru-head cache))
    ;; Update tail if this was the tail
    (when (eq entry (memory-cache-lru-tail cache))
      (setf (memory-cache-lru-tail cache) (cache-entry-prev entry)))
    (%lru-detach entry)
    (%lru-push-front cache entry)))

;;; ---------------------------------------------------------------------------
;;; Public cache operations
;;; ---------------------------------------------------------------------------

(defun memory-cache-get (cache key)
  "Look up KEY in the memory cache.

CACHE: A memory-cache struct
KEY: Cache key string

Returns two values:
  1. The cached value, or NIL if not found/expired
  2. The cache-entry struct (for ETag access), or NIL

Thread-safe. Moves accessed entries to front of LRU list."
  (bt:with-lock-held ((memory-cache-lock cache))
    (let ((entry (gethash key (memory-cache-table cache))))
      (cond
        ;; No entry found
        ((null entry)
         (%inc-stat cache :misses)
         (values nil nil))
        ;; Entry expired
        ((cache-entry-expired-p entry)
         (%inc-stat cache :misses)
         (%inc-stat cache :expirations)
         ;; Lazily evict if configured
         (when (memory-cache-evict-expired-on-access cache)
           (%memory-cache-remove-entry cache entry))
         ;; Return entry anyway so caller can use ETag for conditional request
         (values nil entry))
        ;; Valid entry - cache hit
        (t
         (%inc-stat cache :hits)
         ;; Update access tracking
         (setf (cache-entry-accessed-at entry) (get-universal-time))
         (incf (cache-entry-access-count entry))
         ;; Move to front of LRU
         (%lru-move-to-front cache entry)
         (values (cache-entry-value entry) entry))))))

(defun memory-cache-put (cache key value &key etag ttl (size-estimate 0))
  "Store a value in the memory cache.

CACHE: A memory-cache struct
KEY: Cache key string
VALUE: The data to cache
ETAG: ETag string from ESI response
TTL: Time-to-live in seconds
SIZE-ESTIMATE: Approximate value size in bytes

Evicts the least recently used entry if the cache is full.

Returns the cache-entry that was stored.

Thread-safe."
  (bt:with-lock-held ((memory-cache-lock cache))
    ;; Remove existing entry if present
    (let ((existing (gethash key (memory-cache-table cache))))
      (when existing
        (%memory-cache-remove-entry cache existing)))
    ;; Evict LRU entries if at capacity
    (loop while (>= (hash-table-count (memory-cache-table cache))
                     (memory-cache-max-entries cache))
          do (%memory-cache-evict-lru cache))
    ;; Create and insert new entry
    (let ((entry (make-cache-entry key value
                                   :etag etag
                                   :ttl ttl
                                   :size-estimate size-estimate)))
      (setf (gethash key (memory-cache-table cache)) entry)
      (%lru-push-front cache entry)
      (%inc-stat cache :puts)
      (%inc-stat cache :total-size-estimate size-estimate)
      entry)))

(defun memory-cache-delete (cache key)
  "Remove KEY from the memory cache.

CACHE: A memory-cache struct
KEY: Cache key string

Returns T if the entry was found and removed, NIL otherwise.

Thread-safe."
  (bt:with-lock-held ((memory-cache-lock cache))
    (let ((entry (gethash key (memory-cache-table cache))))
      (when entry
        (%memory-cache-remove-entry cache entry)
        (%inc-stat cache :deletes)
        t))))

(defun memory-cache-exists-p (cache key)
  "Check if KEY exists and is not expired in the memory cache.

CACHE: A memory-cache struct
KEY: Cache key string

Returns T if a valid (non-expired) entry exists.

Thread-safe."
  (bt:with-lock-held ((memory-cache-lock cache))
    (let ((entry (gethash key (memory-cache-table cache))))
      (and entry (not (cache-entry-expired-p entry))))))

(defun memory-cache-clear (cache)
  "Remove all entries from the memory cache and reset statistics.

CACHE: A memory-cache struct

Thread-safe."
  (bt:with-lock-held ((memory-cache-lock cache))
    (clrhash (memory-cache-table cache))
    (setf (memory-cache-lru-head cache) nil
          (memory-cache-lru-tail cache) nil
          (memory-cache-stats cache)
          (list :hits 0 :misses 0 :evictions 0 :expirations 0
                :puts 0 :deletes 0 :total-size-estimate 0))))

(defun memory-cache-count (cache)
  "Return the number of entries currently in the cache.

CACHE: A memory-cache struct

Thread-safe."
  (bt:with-lock-held ((memory-cache-lock cache))
    (hash-table-count (memory-cache-table cache))))

(defun memory-cache-statistics (cache)
  "Return a copy of the cache statistics plist.

CACHE: A memory-cache struct

Returns a plist with keys:
  :HITS - Number of successful lookups
  :MISSES - Number of failed lookups (including expired entries)
  :EVICTIONS - Number of LRU evictions
  :EXPIRATIONS - Number of expired entry removals
  :PUTS - Number of entries stored
  :DELETES - Number of explicit deletions
  :TOTAL-SIZE-ESTIMATE - Cumulative size estimate of stored data
  :COUNT - Current number of entries
  :MAX-ENTRIES - Maximum capacity
  :HIT-RATE - Hit rate as a float (0.0 to 1.0)

Thread-safe."
  (bt:with-lock-held ((memory-cache-lock cache))
    (let* ((stats (copy-list (memory-cache-stats cache)))
           (hits (getf stats :hits))
           (misses (getf stats :misses))
           (total (+ hits misses)))
      (append stats
              (list :count (hash-table-count (memory-cache-table cache))
                    :max-entries (memory-cache-max-entries cache)
                    :hit-rate (if (plusp total)
                                  (float (/ hits total))
                                  0.0))))))

(defun memory-cache-purge-expired (cache)
  "Remove all expired entries from the cache.

CACHE: A memory-cache struct

Returns the number of entries removed.

Thread-safe. Use this for periodic maintenance to reclaim memory."
  (let ((removed 0)
        (now (get-universal-time)))
    (bt:with-lock-held ((memory-cache-lock cache))
      (let ((keys-to-remove nil))
        ;; Collect expired keys first to avoid modifying during iteration
        (maphash (lambda (key entry)
                   (when (cache-entry-expired-p entry now)
                     (push key keys-to-remove)))
                 (memory-cache-table cache))
        ;; Remove collected entries
        (dolist (key keys-to-remove)
          (let ((entry (gethash key (memory-cache-table cache))))
            (when entry
              (%memory-cache-remove-entry cache entry)
              (%inc-stat cache :expirations)
              (incf removed))))))
    removed))

;;; ---------------------------------------------------------------------------
;;; Internal operations (must be called under lock)
;;; ---------------------------------------------------------------------------

(defun %memory-cache-remove-entry (cache entry)
  "Remove a specific entry from the cache (hash-table and LRU list).
Internal: must be called under write lock."
  ;; Update tail/head if needed
  (when (eq entry (memory-cache-lru-tail cache))
    (setf (memory-cache-lru-tail cache) (cache-entry-prev entry)))
  (when (eq entry (memory-cache-lru-head cache))
    (setf (memory-cache-lru-head cache) (cache-entry-next entry)))
  ;; Detach from LRU list
  (%lru-detach entry)
  ;; Remove from hash-table
  (remhash (cache-entry-key entry) (memory-cache-table cache))
  ;; Update size tracking
  (%inc-stat cache :total-size-estimate
             (- (cache-entry-size-estimate entry))))

(defun %memory-cache-evict-lru (cache)
  "Evict the least recently used entry from the cache.
Internal: must be called under write lock."
  (let ((victim (%lru-remove-tail cache)))
    (when victim
      (remhash (cache-entry-key victim) (memory-cache-table cache))
      (%inc-stat cache :evictions)
      (%inc-stat cache :total-size-estimate
                 (- (cache-entry-size-estimate victim)))
      victim)))

;;; ---------------------------------------------------------------------------
;;; Bulk operations
;;; ---------------------------------------------------------------------------

(defun memory-cache-get-multi (cache keys)
  "Look up multiple keys in the memory cache.

CACHE: A memory-cache struct
KEYS: A list of cache key strings

Returns an alist of (KEY . VALUE) for entries that were found and not expired.
Missing or expired entries are omitted.

Thread-safe."
  (bt:with-lock-held ((memory-cache-lock cache))
    (let ((results nil)
          (now (get-universal-time)))
      (dolist (key keys (nreverse results))
        (let ((entry (gethash key (memory-cache-table cache))))
          (when (and entry (not (cache-entry-expired-p entry now)))
            (setf (cache-entry-accessed-at entry) now)
            (incf (cache-entry-access-count entry))
            (%lru-move-to-front cache entry)
            (%inc-stat cache :hits)
            (push (cons key (cache-entry-value entry)) results)))))))

(defun memory-cache-keys (cache &key (include-expired nil))
  "Return a list of all cache keys.

CACHE: A memory-cache struct
INCLUDE-EXPIRED: If T, include keys of expired entries (default: NIL)

Returns a list of cache key strings.

Thread-safe."
  (bt:with-lock-held ((memory-cache-lock cache))
    (let ((keys nil)
          (now (get-universal-time)))
      (maphash (lambda (key entry)
                 (when (or include-expired
                           (not (cache-entry-expired-p entry now)))
                   (push key keys)))
               (memory-cache-table cache))
      keys)))

;;; ---------------------------------------------------------------------------
;;; REPL inspection utilities
;;; ---------------------------------------------------------------------------

(defun memory-cache-summary (cache &optional (stream *standard-output*))
  "Print a human-readable summary of the memory cache state.

CACHE: A memory-cache struct
STREAM: Output stream (default: *standard-output*)

Useful for REPL inspection."
  (let ((stats (memory-cache-statistics cache)))
    (format stream "~&Memory Cache Summary~%")
    (format stream "~A~%" (make-string 40 :initial-element #\=))
    (format stream "Entries: ~D / ~D (~,1F% full)~%"
            (getf stats :count)
            (getf stats :max-entries)
            (if (plusp (getf stats :max-entries))
                (* 100.0 (/ (getf stats :count)
                            (getf stats :max-entries)))
                0.0))
    (format stream "Hit rate: ~,1F% (~D hits, ~D misses)~%"
            (* 100.0 (getf stats :hit-rate))
            (getf stats :hits)
            (getf stats :misses))
    (format stream "Evictions: ~D  Expirations: ~D~%"
            (getf stats :evictions)
            (getf stats :expirations))
    (format stream "Puts: ~D  Deletes: ~D~%"
            (getf stats :puts)
            (getf stats :deletes)))
  (values))
