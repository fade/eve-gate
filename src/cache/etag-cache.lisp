;;;; etag-cache.lisp - ETag-based conditional request cache for eve-gate
;;;;
;;;; Implements ETag tracking and conditional request support for the ESI API.
;;;; ETags are lightweight identifiers that ESI returns with every response.
;;;; When we send an If-None-Match header with a cached ETag, ESI returns
;;;; 304 Not Modified if the data hasn't changed, saving bandwidth and
;;;; avoiding counting against rate limits.
;;;;
;;;; This is a critical optimization for ESI because:
;;;;   1. ESI doesn't count 304 responses against the error limit
;;;;   2. 304 responses are much smaller than full responses
;;;;   3. Many ESI endpoints change infrequently (e.g., character public info)
;;;;
;;;; The ETag cache is a separate, lightweight structure from the main data
;;;; caches. It maps cache keys to ETags, and survives even when the data
;;;; has been evicted from L1 memory cache. This allows us to make
;;;; conditional requests even after LRU eviction.
;;;;
;;;; Design: The ETag cache is intentionally simple - just a bounded
;;;; hash-table with oldest-first eviction. ETags are small strings,
;;;; so even with 50k entries the memory footprint is trivial.

(in-package #:eve-gate.cache)

;;; ---------------------------------------------------------------------------
;;; ETag entry structure
;;; ---------------------------------------------------------------------------

(defstruct (etag-entry (:constructor %make-etag-entry))
  "A cached ETag for a specific cache key.

Slots:
  ETAG: The ETag string from the ESI response
  CACHED-AT: Universal-time when this ETag was stored
  LAST-USED: Universal-time of last conditional request using this ETag
  USE-COUNT: Number of times this ETag was used in conditional requests
  LAST-STATUS: HTTP status of the last conditional request (200 or 304)"
  (etag "" :type string)
  (cached-at (get-universal-time) :type integer)
  (last-used (get-universal-time) :type integer)
  (use-count 0 :type fixnum)
  (last-status nil :type (or null integer)))

;;; ---------------------------------------------------------------------------
;;; ETag cache structure
;;; ---------------------------------------------------------------------------

(defstruct (etag-cache (:constructor %make-etag-cache))
  "Cache for ETag values used in conditional ESI requests.

Tracks ETags separately from response data so conditional requests
can be made even after data has been evicted from memory.

Slots:
  TABLE: Hash-table mapping cache keys to etag-entry structs
  MAX-ENTRIES: Maximum number of ETag entries to track
  LOCK: Lock for thread safety
  STATS: Statistics plist"
  (table (make-hash-table :test 'equal) :type hash-table)
  (max-entries 50000 :type fixnum)
  (lock (bt:make-lock "etag-cache-lock"))
  (stats (list :hits-304 0 :misses-200 0 :stores 0 :evictions 0)
         :type list))

(defun make-etag-cache (&key (max-entries 50000))
  "Create a new ETag cache.

MAX-ENTRIES: Maximum number of ETags to track (default: 50000)
  ETags are small (~40 bytes each), so 50k entries use ~2MB.

Returns an ETAG-CACHE struct."
  (%make-etag-cache :max-entries max-entries))

;;; ---------------------------------------------------------------------------
;;; Public operations
;;; ---------------------------------------------------------------------------

(defun etag-cache-get (cache key)
  "Look up the cached ETag for KEY.

CACHE: An etag-cache struct
KEY: Cache key string

Returns the ETag string, or NIL if no ETag is cached for this key.

Thread-safe."
  (bt:with-lock-held ((etag-cache-lock cache))
    (let ((entry (gethash key (etag-cache-table cache))))
      (when entry
        (setf (etag-entry-last-used entry) (get-universal-time))
        (incf (etag-entry-use-count entry))
        (etag-entry-etag entry)))))

(defun etag-cache-put (cache key etag)
  "Store an ETag for KEY in the cache.

CACHE: An etag-cache struct
KEY: Cache key string
ETAG: The ETag string from an ESI response

Evicts oldest entries if the cache is full.

Returns the ETAG string.

Thread-safe."
  (when (and etag (plusp (length etag)))
    (bt:with-lock-held ((etag-cache-lock cache))
      ;; Evict if at capacity (and this is a new key)
      (unless (gethash key (etag-cache-table cache))
        (loop while (>= (hash-table-count (etag-cache-table cache))
                        (etag-cache-max-entries cache))
              do (%etag-cache-evict-oldest cache)))
      ;; Store/update the entry
      (setf (gethash key (etag-cache-table cache))
            (%make-etag-entry :etag etag))
      (incf (getf (etag-cache-stats cache) :stores))
      etag)))

(defun etag-cache-record-result (cache key status)
  "Record the result of a conditional request using a cached ETag.

CACHE: An etag-cache struct
KEY: Cache key string
STATUS: HTTP status code (304 for cache hit, 200 for miss/changed)

Updates statistics and the entry's last-status.

Thread-safe."
  (bt:with-lock-held ((etag-cache-lock cache))
    (let ((entry (gethash key (etag-cache-table cache))))
      (when entry
        (setf (etag-entry-last-status entry) status)
        (if (= status 304)
            (incf (getf (etag-cache-stats cache) :hits-304))
            (incf (getf (etag-cache-stats cache) :misses-200)))))))

(defun etag-cache-delete (cache key)
  "Remove the cached ETag for KEY.

CACHE: An etag-cache struct
KEY: Cache key string

Returns T if an entry was removed, NIL otherwise.

Thread-safe."
  (bt:with-lock-held ((etag-cache-lock cache))
    (not (null (remhash key (etag-cache-table cache))))))

(defun etag-cache-clear (cache)
  "Remove all entries from the ETag cache.

CACHE: An etag-cache struct

Thread-safe."
  (bt:with-lock-held ((etag-cache-lock cache))
    (clrhash (etag-cache-table cache))
    (setf (etag-cache-stats cache)
          (list :hits-304 0 :misses-200 0 :stores 0 :evictions 0))))

(defun etag-cache-count (cache)
  "Return the number of entries in the ETag cache.

Thread-safe."
  (bt:with-lock-held ((etag-cache-lock cache))
    (hash-table-count (etag-cache-table cache))))

(defun etag-cache-statistics (cache)
  "Return a copy of the ETag cache statistics.

Returns a plist with keys:
  :HITS-304 - Number of 304 Not Modified responses
  :MISSES-200 - Number of 200 OK responses (data changed)
  :STORES - Number of ETags stored
  :EVICTIONS - Number of ETags evicted
  :COUNT - Current number of entries
  :SAVINGS-RATE - Rate of bandwidth savings (304s / total conditional requests)

Thread-safe."
  (bt:with-lock-held ((etag-cache-lock cache))
    (let* ((stats (copy-list (etag-cache-stats cache)))
           (hits (getf stats :hits-304))
           (misses (getf stats :misses-200))
           (total (+ hits misses)))
      (append stats
              (list :count (hash-table-count (etag-cache-table cache))
                    :max-entries (etag-cache-max-entries cache)
                    :savings-rate (if (plusp total)
                                      (float (/ hits total))
                                      0.0))))))

;;; ---------------------------------------------------------------------------
;;; Internal operations (must be called under lock)
;;; ---------------------------------------------------------------------------

(defun %etag-cache-evict-oldest (cache)
  "Evict the oldest entry from the ETag cache.
Internal: must be called under lock."
  (let ((oldest-key nil)
        (oldest-time most-positive-fixnum))
    (maphash (lambda (key entry)
               (when (< (etag-entry-cached-at entry) oldest-time)
                 (setf oldest-key key
                       oldest-time (etag-entry-cached-at entry))))
             (etag-cache-table cache))
    (when oldest-key
      (remhash oldest-key (etag-cache-table cache))
      (incf (getf (etag-cache-stats cache) :evictions)))))

;;; ---------------------------------------------------------------------------
;;; REPL inspection
;;; ---------------------------------------------------------------------------

(defun etag-cache-summary (cache &optional (stream *standard-output*))
  "Print a human-readable summary of the ETag cache state.

CACHE: An etag-cache struct
STREAM: Output stream (default: *standard-output*)"
  (let ((stats (etag-cache-statistics cache)))
    (format stream "~&ETag Cache Summary~%")
    (format stream "~A~%" (make-string 40 :initial-element #\=))
    (format stream "Entries: ~D / ~D~%"
            (getf stats :count)
            (getf stats :max-entries))
    (format stream "Bandwidth savings: ~,1F% (~D/~D conditional hits)~%"
            (* 100.0 (getf stats :savings-rate))
            (getf stats :hits-304)
            (+ (getf stats :hits-304) (getf stats :misses-200)))
    (format stream "Total ETags stored: ~D  Evictions: ~D~%"
            (getf stats :stores)
            (getf stats :evictions)))
  (values))
