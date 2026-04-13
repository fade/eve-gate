;;;; database-cache.lisp - Persistent database cache (L2) for eve-gate
;;;;
;;;; Implements the L2 (persistent) tier of the two-level cache architecture.
;;;; Uses a simple file-based storage approach that doesn't require an external
;;;; database. Data is serialized as JSON and stored in a directory structure
;;;; keyed by the cache key hash.
;;;;
;;;; The database cache serves two purposes:
;;;;   1. Cache persistence across application restarts
;;;;   2. Overflow storage for data evicted from the L1 memory cache
;;;;
;;;; When data is evicted from L1 memory, it may still exist in L2 persistent
;;;; storage. This is especially valuable for ESI data that changes slowly
;;;; (e.g., universe data, type info, character public info).
;;;;
;;;; Design: Simple file-based storage for portability.
;;;; Each entry is a JSON file in a directory tree keyed by MD5 hash of the
;;;; cache key. This avoids requiring Mito/PostgreSQL for basic caching.
;;;; A Mito-based implementation can be added later as an alternative backend.
;;;;
;;;; File layout:
;;;;   <cache-dir>/
;;;;     <hash[0:2]>/
;;;;       <hash[2:4]>/
;;;;         <full-hash>.json    # { "key": ..., "value": ..., "etag": ..., ... }

(in-package #:eve-gate.cache)

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(defparameter *database-cache-directory*
  (merge-pathnames ".cache/eve-gate/" (user-homedir-pathname))
  "Base directory for persistent cache files.
Default is ~/.cache/eve-gate/")

;;; ---------------------------------------------------------------------------
;;; Database cache structure
;;; ---------------------------------------------------------------------------

(defstruct (database-cache (:constructor %make-database-cache))
  "File-based persistent cache (L2 tier).

Stores cached ESI responses as JSON files in a directory structure.
Survives application restarts and can store data evicted from L1 memory.

Slots:
  DIRECTORY: Base directory for cache files
  ENABLED-P: Whether the database cache is active
  LOCK: Lock for thread safety during file I/O
  STATS: Statistics plist
  MAX-AGE: Maximum age in seconds for cache files (for periodic cleanup)"
  (directory *database-cache-directory* :type pathname)
  (enabled-p t :type boolean)
  (lock (bt:make-lock "database-cache-lock"))
  (stats (list :hits 0 :misses 0 :puts 0 :deletes 0 :errors 0)
         :type list)
  (max-age (* 7 24 60 60) :type integer)) ; 7 days default

(defun make-database-cache (&key (directory *database-cache-directory*)
                                  (enabled t)
                                  (max-age (* 7 24 60 60)))
  "Create a new database cache.

DIRECTORY: Base directory for cache files (default: ~/.cache/eve-gate/)
ENABLED: Whether the cache is active (default: T)
MAX-AGE: Maximum age of cache files in seconds (default: 7 days)

Returns a DATABASE-CACHE struct.

Example:
  (make-database-cache :directory #P\"/tmp/eve-cache/\")"
  (let ((dir (pathname directory)))
    (%make-database-cache
     :directory dir
     :enabled-p enabled
     :max-age max-age)))

;;; ---------------------------------------------------------------------------
;;; Cache key hashing
;;; ---------------------------------------------------------------------------

(defun %cache-key-hash (key)
  "Compute a hash string from a cache key for filesystem storage.
Uses a simple but deterministic hash function to create a path-safe string.

KEY: Cache key string
Returns a 16-character hex string."
  ;; Simple FNV-1a-style hash producing a 64-bit value rendered as hex.
  ;; Good distribution, deterministic, and fast.
  (let ((hash #xCBF29CE484222325)) ; FNV offset basis (64-bit)
    (declare (type (unsigned-byte 64) hash))
    (loop for char across key
          do (setf hash (logxor hash (char-code char)))
             (setf hash (logand #xFFFFFFFFFFFFFFFF
                                (* hash #x100000001B3)))) ; FNV prime
    (format nil "~16,'0X" hash)))

(defun %cache-file-path (cache key)
  "Compute the filesystem path for a cache entry.

CACHE: A database-cache struct
KEY: Cache key string

Returns a pathname for the cache file."
  (let* ((hash (%cache-key-hash key))
         (dir1 (subseq hash 0 2))
         (dir2 (subseq hash 2 4)))
    (merge-pathnames
     (make-pathname :directory (list :relative dir1 dir2)
                    :name hash
                    :type "json")
     (database-cache-directory cache))))

;;; ---------------------------------------------------------------------------
;;; Serialization
;;; ---------------------------------------------------------------------------

(defun %serialize-cache-entry (key value etag expires-at)
  "Serialize a cache entry to a JSON string for file storage.

KEY: Cache key string
VALUE: The cached data
ETAG: ETag string
EXPIRES-AT: Universal-time expiry

Returns a JSON string."
  (let ((entry (make-hash-table :test 'equal)))
    (setf (gethash "key" entry) key
          (gethash "etag" entry) (or etag "")
          (gethash "expires_at" entry) expires-at
          (gethash "cached_at" entry) (get-universal-time)
          (gethash "value" entry) value)
    (com.inuoe.jzon:stringify entry)))

(defun %deserialize-cache-entry (json-string)
  "Deserialize a cache entry from a JSON string.

JSON-STRING: The JSON content of a cache file

Returns multiple values: value, etag, expires-at, or NIL on failure."
  (handler-case
      (let ((data (com.inuoe.jzon:parse json-string)))
        (when (hash-table-p data)
          (values (gethash "value" data)
                  (let ((etag (gethash "etag" data)))
                    (when (and etag (plusp (length etag))) etag))
                  (gethash "expires_at" data)
                  (gethash "cached_at" data))))
    (error (e)
      (log-warn "Failed to deserialize cache entry: ~A" e)
      (values nil nil nil nil))))

;;; ---------------------------------------------------------------------------
;;; Public operations
;;; ---------------------------------------------------------------------------

(defun database-cache-get (cache key)
  "Look up KEY in the database cache.

CACHE: A database-cache struct
KEY: Cache key string

Returns two values:
  1. The cached value, or NIL if not found/expired
  2. The ETag string, or NIL

Thread-safe."
  (unless (database-cache-enabled-p cache)
    (return-from database-cache-get (values nil nil)))
  (bt:with-lock-held ((database-cache-lock cache))
    (let ((path (%cache-file-path cache key)))
      (handler-case
          (if (probe-file path)
              (let ((content (with-open-file (stream path :direction :input
                                                          :external-format :utf-8)
                               (let ((buf (make-string (file-length stream))))
                                 (read-sequence buf stream)
                                 buf))))
                (multiple-value-bind (value etag expires-at)
                    (%deserialize-cache-entry content)
                  (cond
                    ;; Entry expired
                    ((and expires-at (> (get-universal-time) expires-at))
                     (incf (getf (database-cache-stats cache) :misses))
                     ;; Return etag even for expired entries (conditional request)
                     (values nil etag))
                    ;; Valid entry
                    (value
                     (incf (getf (database-cache-stats cache) :hits))
                     (values value etag))
                    ;; Deserialization failure
                    (t
                     (incf (getf (database-cache-stats cache) :misses))
                     (values nil nil)))))
              ;; File not found
              (progn
                (incf (getf (database-cache-stats cache) :misses))
                (values nil nil)))
        (error (e)
          (log-warn "Database cache read error for ~A: ~A" key e)
          (incf (getf (database-cache-stats cache) :errors))
          (values nil nil))))))

(defun database-cache-put (cache key value &key etag ttl)
  "Store a value in the database cache.

CACHE: A database-cache struct
KEY: Cache key string
VALUE: The data to cache (must be JSON-serializable)
ETAG: ETag string from ESI response
TTL: Time-to-live in seconds

Returns T on success, NIL on failure.

Thread-safe."
  (unless (database-cache-enabled-p cache)
    (return-from database-cache-put nil))
  (bt:with-lock-held ((database-cache-lock cache))
    (let ((path (%cache-file-path cache key))
          (expires-at (if ttl
                         (+ (get-universal-time) ttl)
                         (+ (get-universal-time) 
                            (database-cache-max-age cache)))))
      (handler-case
          (progn
            ;; Ensure directory exists
            (ensure-directories-exist path)
            ;; Write atomically via temp file
            (let* ((temp-path (make-pathname :name (format nil "~A.tmp"
                                                           (pathname-name path))
                                             :defaults path))
                   (json (%serialize-cache-entry key value etag expires-at)))
              (with-open-file (stream temp-path
                                      :direction :output
                                      :if-exists :supersede
                                      :external-format :utf-8)
                (write-string json stream))
              ;; Rename for atomic update
              (rename-file temp-path path))
            (incf (getf (database-cache-stats cache) :puts))
            t)
        (error (e)
          (log-warn "Database cache write error for ~A: ~A" key e)
          (incf (getf (database-cache-stats cache) :errors))
          nil)))))

(defun database-cache-delete (cache key)
  "Remove KEY from the database cache.

CACHE: A database-cache struct
KEY: Cache key string

Returns T if the file was removed, NIL otherwise.

Thread-safe."
  (unless (database-cache-enabled-p cache)
    (return-from database-cache-delete nil))
  (bt:with-lock-held ((database-cache-lock cache))
    (let ((path (%cache-file-path cache key)))
      (handler-case
          (when (probe-file path)
            (delete-file path)
            (incf (getf (database-cache-stats cache) :deletes))
            t)
        (error (e)
          (log-warn "Database cache delete error for ~A: ~A" key e)
          (incf (getf (database-cache-stats cache) :errors))
          nil)))))

(defun database-cache-exists-p (cache key)
  "Check if KEY exists in the database cache (file exists).

CACHE: A database-cache struct
KEY: Cache key string

Returns T if a cache file exists for this key.

Thread-safe."
  (unless (database-cache-enabled-p cache)
    (return-from database-cache-exists-p nil))
  (bt:with-lock-held ((database-cache-lock cache))
    (not (null (probe-file (%cache-file-path cache key))))))

(defun database-cache-clear (cache)
  "Remove all entries from the database cache.

CACHE: A database-cache struct

Deletes the entire cache directory tree and recreates it.

Thread-safe."
  (unless (database-cache-enabled-p cache)
    (return-from database-cache-clear nil))
  (bt:with-lock-held ((database-cache-lock cache))
    (let ((dir (database-cache-directory cache)))
      (handler-case
          (when (probe-file dir)
            ;; Remove all .json files in the cache directory tree
            (let ((files (directory (merge-pathnames "**/*.json" dir))))
              (dolist (file files)
                (handler-case (delete-file file) (error () nil))))
            ;; Reset stats
            (setf (database-cache-stats cache)
                  (list :hits 0 :misses 0 :puts 0 :deletes 0 :errors 0))
            t)
        (error (e)
          (log-warn "Database cache clear error: ~A" e)
          nil)))))

(defun database-cache-statistics (cache)
  "Return a copy of the database cache statistics.

Returns a plist with keys:
  :HITS - Number of successful lookups
  :MISSES - Number of failed lookups
  :PUTS - Number of entries stored
  :DELETES - Number of entries deleted
  :ERRORS - Number of I/O errors
  :ENABLED - Whether the cache is active

Thread-safe."
  (bt:with-lock-held ((database-cache-lock cache))
    (let ((stats (copy-list (database-cache-stats cache))))
      (append stats
              (list :enabled (database-cache-enabled-p cache))))))

;;; ---------------------------------------------------------------------------
;;; Maintenance
;;; ---------------------------------------------------------------------------

(defun database-cache-purge-expired (cache)
  "Remove all expired entries from the database cache.

CACHE: A database-cache struct

Returns the number of entries removed.

Thread-safe. This is an expensive operation that scans all cache files."
  (unless (database-cache-enabled-p cache)
    (return-from database-cache-purge-expired 0))
  (let ((removed 0)
        (now (get-universal-time)))
    (bt:with-lock-held ((database-cache-lock cache))
      (let ((dir (database-cache-directory cache)))
        (handler-case
            (when (probe-file dir)
              (let ((files (directory (merge-pathnames "**/*.json" dir))))
                (dolist (file files)
                  (handler-case
                      (let ((content (with-open-file (s file :direction :input
                                                             :external-format :utf-8)
                                       (let ((buf (make-string (file-length s))))
                                         (read-sequence buf s)
                                         buf))))
                        (multiple-value-bind (value etag expires-at)
                            (%deserialize-cache-entry content)
                          (declare (ignore value etag))
                          (when (and expires-at (> now expires-at))
                            (delete-file file)
                            (incf removed))))
                    (error () nil)))))
          (error (e)
            (log-warn "Database cache purge error: ~A" e)))))
    removed))

;;; ---------------------------------------------------------------------------
;;; REPL inspection
;;; ---------------------------------------------------------------------------

(defun database-cache-summary (cache &optional (stream *standard-output*))
  "Print a human-readable summary of the database cache state.

CACHE: A database-cache struct
STREAM: Output stream (default: *standard-output*)"
  (let ((stats (database-cache-statistics cache)))
    (format stream "~&Database Cache Summary~%")
    (format stream "~A~%" (make-string 40 :initial-element #\=))
    (format stream "Enabled: ~A~%" (getf stats :enabled))
    (format stream "Directory: ~A~%" (database-cache-directory cache))
    (format stream "Hits: ~D  Misses: ~D~%"
            (getf stats :hits)
            (getf stats :misses))
    (format stream "Puts: ~D  Deletes: ~D  Errors: ~D~%"
            (getf stats :puts)
            (getf stats :deletes)
            (getf stats :errors))
    (format stream "Max age: ~D seconds (~,1F days)~%"
            (database-cache-max-age cache)
            (/ (database-cache-max-age cache) 86400.0)))
  (values))
