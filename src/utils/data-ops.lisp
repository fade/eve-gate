;;;; data-ops.lisp - Data operations integration and monitoring for eve-gate
;;;;
;;;; Provides the orchestration layer for data export/import operations,
;;;; integrating with the existing caching, authentication, and configuration
;;;; subsystems. Handles job scheduling, progress tracking, data integrity
;;;; verification, and backup/disaster recovery utilities.
;;;;
;;;; This module ties together:
;;;;   - formats.lisp: encoding/decoding
;;;;   - export.lisp: export job execution
;;;;   - import.lisp: import job execution
;;;;   - data-privacy.lisp: privacy controls
;;;;   - audit-logger.lisp: audit trail
;;;;   - configuration.lisp: configuration integration
;;;;
;;;; Thread safety: Job tracking uses locks. Individual export/import
;;;; operations are sequential within a job but multiple jobs can run
;;;; concurrently in separate threads.

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Data operations manager
;;; ---------------------------------------------------------------------------

(defstruct (data-ops-manager (:constructor %make-data-ops-manager))
  "Central manager for data operations (export/import jobs).

Slots:
  LOCK: Mutex for thread-safe access to job tracking
  ACTIVE-JOBS: Hash table of currently running jobs by ID
  COMPLETED-JOBS: Ring buffer of recently completed jobs
  MAX-COMPLETED: Maximum completed jobs to retain
  TOTAL-EXPORTS: Count of total exports performed
  TOTAL-IMPORTS: Count of total imports performed
  DEFAULT-FORMAT: Default export format
  DEFAULT-EXPORT-DIR: Default directory for export files
  DEFAULT-IMPORT-DIR: Default directory for import files"
  (lock (bt:make-lock "data-ops-lock"))
  (active-jobs (make-hash-table :test 'eq) :type hash-table)
  (completed-jobs '() :type list)
  (max-completed 100 :type fixnum)
  (total-exports 0 :type integer)
  (total-imports 0 :type integer)
  (default-format :json :type keyword)
  (default-export-dir nil :type (or null string pathname))
  (default-import-dir nil :type (or null string pathname)))

(defvar *data-ops-manager* nil
  "Global data operations manager instance.")

(defun initialize-data-ops (&key (default-format :json)
                                   default-export-dir
                                   default-import-dir)
  "Initialize the data operations manager.

DEFAULT-FORMAT: Default export format (default: :json)
DEFAULT-EXPORT-DIR: Default export directory
DEFAULT-IMPORT-DIR: Default import directory

Returns the manager instance."
  (setf *data-ops-manager*
        (%make-data-ops-manager
         :default-format default-format
         :default-export-dir default-export-dir
         :default-import-dir default-import-dir))
  (log-info "Data operations manager initialized (format: ~A)" default-format)
  *data-ops-manager*)

(defun ensure-data-ops-manager ()
  "Ensure the data operations manager is initialized."
  (or *data-ops-manager*
      (initialize-data-ops)))

;;; ---------------------------------------------------------------------------
;;; Job tracking
;;; ---------------------------------------------------------------------------

(defun track-job (job-id job &key (type :export))
  "Register a job for tracking.

JOB-ID: Job identifier symbol
JOB: The export-job or import-job struct
TYPE: :export or :import"
  (let ((mgr (ensure-data-ops-manager)))
    (bt:with-lock-held ((data-ops-manager-lock mgr))
      (setf (gethash job-id (data-ops-manager-active-jobs mgr))
            (list :type type :job job :started-at (get-universal-time))))))

(defun complete-tracked-job (job-id)
  "Move a job from active to completed.

JOB-ID: Job identifier symbol"
  (let ((mgr (ensure-data-ops-manager)))
    (bt:with-lock-held ((data-ops-manager-lock mgr))
      (when-let ((entry (gethash job-id (data-ops-manager-active-jobs mgr))))
        (remhash job-id (data-ops-manager-active-jobs mgr))
        (push (append entry (list :completed-at (get-universal-time)))
              (data-ops-manager-completed-jobs mgr))
        ;; Trim completed jobs
        (when (> (length (data-ops-manager-completed-jobs mgr))
                 (data-ops-manager-max-completed mgr))
          (setf (data-ops-manager-completed-jobs mgr)
                (subseq (data-ops-manager-completed-jobs mgr)
                        0 (data-ops-manager-max-completed mgr))))
        ;; Update counters
        (ecase (getf entry :type)
          (:export (incf (data-ops-manager-total-exports mgr)))
          (:import (incf (data-ops-manager-total-imports mgr))))))))

;;; ---------------------------------------------------------------------------
;;; Managed export operations
;;; ---------------------------------------------------------------------------

(defun managed-export (name records &key (format nil)
                                          (data-category :unknown)
                                          character-id
                                          destination
                                          options)
  "Execute a managed export with job tracking and monitoring.

NAME: Export name
RECORDS: Data to export
FORMAT: Output format (NIL uses manager default)
DATA-CATEGORY: ESI data category
CHARACTER-ID: Character ID for character-specific exports
DESTINATION: File path (NIL for string output)
OPTIONS: Additional export options plist

Returns (VALUES export-job result-string-or-path)."
  (let* ((mgr (ensure-data-ops-manager))
         (actual-format (or format (data-ops-manager-default-format mgr)))
         (actual-dest (or destination
                         (when (data-ops-manager-default-export-dir mgr)
                           (merge-pathnames
                            (format nil "~A-~A.~A"
                                    (string-downcase (symbol-name data-category))
                                    (get-universal-time)
                                    (format-extension actual-format))
                            (data-ops-manager-default-export-dir mgr)))))
         (job (make-export-job name records
                                :format actual-format
                                :data-category data-category
                                :character-id character-id
                                :destination actual-dest
                                :options options)))
    ;; Track
    (track-job (export-job-id job) job :type :export)
    ;; Execute
    (multiple-value-bind (result-job result)
        (execute-export job)
      (complete-tracked-job (export-job-id result-job))
      (values result-job result))))

;;; ---------------------------------------------------------------------------
;;; Managed import operations
;;; ---------------------------------------------------------------------------

(defun managed-import (name source &key (format :auto)
                                          (data-category :unknown)
                                          (merge-strategy :skip)
                                          schema
                                          existing-data
                                          options)
  "Execute a managed import with job tracking.

NAME: Import name
SOURCE: File path or string data
FORMAT: Input format (default: :auto)
DATA-CATEGORY: ESI data category
MERGE-STRATEGY: Conflict resolution strategy
SCHEMA: Validation schema
EXISTING-DATA: Current data for conflict detection
OPTIONS: Additional import options plist

Returns (VALUES import-job imported-records)."
  (let ((job (make-import-job name source
                               :format format
                               :data-category data-category
                               :merge-strategy merge-strategy
                               :options (append
                                         (list :schema schema)
                                         options))))
    ;; Track
    (track-job (import-job-id job) job :type :import)
    ;; Execute
    (multiple-value-bind (result-job result)
        (execute-import job :existing-data existing-data)
      (complete-tracked-job (import-job-id result-job))
      (values result-job result))))

;;; ---------------------------------------------------------------------------
;;; Data integrity verification
;;; ---------------------------------------------------------------------------

(defun compute-data-checksum (records)
  "Compute a checksum for a list of RECORDS for integrity verification.

Uses SXHASH-based checksum which is fast but implementation-dependent.
Suitable for same-Lisp-image verification.

RECORDS: List of plists

Returns an integer checksum."
  (let ((hash 0))
    (dolist (record records)
      (setf hash (logxor hash (sxhash record))))
    hash))

(defun verify-data-integrity (records expected-checksum)
  "Verify that RECORDS match the EXPECTED-CHECKSUM.

RECORDS: List of plists
EXPECTED-CHECKSUM: Expected checksum value

Returns (VALUES match-p actual-checksum)."
  (let ((actual (compute-data-checksum records)))
    (values (= actual expected-checksum) actual)))

(defun create-integrity-manifest (records &key data-category export-id)
  "Create an integrity manifest for a dataset.

RECORDS: The dataset
DATA-CATEGORY: Data category
EXPORT-ID: Associated export ID

Returns a plist manifest."
  (list :checksum (compute-data-checksum records)
        :record-count (length records)
        :data-category data-category
        :export-id export-id
        :created-at (format-export-timestamp (get-universal-time))
        :eve-gate-version "0.1.0"
        :lisp-implementation (lisp-implementation-type)
        :lisp-version (lisp-implementation-version)))

(defun verify-against-manifest (records manifest)
  "Verify RECORDS against a previously created MANIFEST.

Returns (VALUES match-p details) where details is a plist of check results."
  (let* ((expected-checksum (getf manifest :checksum))
         (expected-count (getf manifest :record-count))
         (actual-count (length records))
         (checksum-match (when expected-checksum
                           (verify-data-integrity records expected-checksum)))
         (count-match (= actual-count expected-count)))
    (values (and checksum-match count-match)
            (list :checksum-match checksum-match
                  :count-match count-match
                  :expected-count expected-count
                  :actual-count actual-count))))

;;; ---------------------------------------------------------------------------
;;; Backup and restore utilities
;;; ---------------------------------------------------------------------------

(defun create-backup (data-by-category directory &key (format :json)
                                                        (include-manifest t)
                                                        (pretty nil))
  "Create a complete backup of multiple data categories.

DATA-BY-CATEGORY: Plist mapping data-category keywords to record lists
DIRECTORY: Backup directory path
FORMAT: Export format (default: :json)
INCLUDE-MANIFEST: Whether to write a manifest file (default: T)
PRETTY: Pretty-print output

Returns a plist summarizing the backup:
  :directory - Backup directory
  :files - List of files written
  :total-records - Total records backed up
  :manifest-path - Path to manifest file (if created)"
  (ensure-directories-exist (merge-pathnames "dummy" directory))
  (let ((files '())
        (total-records 0)
        (manifests '()))
    ;; Export each category
    (loop for (category records) on data-by-category by #'cddr
          for filename = (format nil "~A.~A"
                                 (string-downcase (symbol-name category))
                                 (format-extension format))
          for path = (merge-pathnames filename directory)
          do (let ((normalized (ensure-list-of-plists records)))
               (with-open-file (stream path
                                       :direction :output
                                       :if-exists :supersede
                                       :if-does-not-exist :create
                                       :external-format :utf-8)
                 (encode-data (list :metadata
                                    (list :data-category category
                                          :record-count (length normalized)
                                          :backed-up-at (format-export-timestamp
                                                         (get-universal-time)))
                                    :data normalized)
                              format stream :pretty pretty))
               (push (namestring path) files)
               (incf total-records (length normalized))
               (push (list :category category
                           :file filename
                           :record-count (length normalized)
                           :checksum (compute-data-checksum normalized))
                     manifests)))
    ;; Write manifest
    (let ((manifest-path nil))
      (when include-manifest
        (setf manifest-path (merge-pathnames "manifest.json" directory))
        (let ((manifest (list :backup-type :full
                              :created-at (format-export-timestamp (get-universal-time))
                              :eve-gate-version "0.1.0"
                              :format format
                              :total-records total-records
                              :categories (nreverse manifests))))
          (with-open-file (stream manifest-path
                                  :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create
                                  :external-format :utf-8)
            (encode-data manifest :json stream :pretty t))))
      ;; Audit
      (when *audit-enabled-p*
        (record-audit-entry
         (%make-audit-entry
          :event-type :data-backup
          :action :create
          :status :success
          :details (list :directory (namestring directory)
                         :total-records total-records
                         :format format
                         :file-count (length files)))))
      (log-info "Backup created: ~D records in ~D files at ~A"
                total-records (length files) directory)
      (list :directory (namestring directory)
            :files (nreverse files)
            :total-records total-records
            :manifest-path (when manifest-path (namestring manifest-path))))))

(defun restore-backup (directory &key (format :auto) category-filter)
  "Restore data from a backup directory.

DIRECTORY: Backup directory path
FORMAT: Format override (default: :auto, detects from files)
CATEGORY-FILTER: List of data categories to restore (NIL = all)

Returns a plist mapping data-category keywords to restored record lists."
  ;; Read manifest if present
  (let ((manifest-path (merge-pathnames "manifest.json" directory))
        (manifest nil)
        (result '()))
    (when (probe-file manifest-path)
      (with-open-file (stream manifest-path :direction :input
                                             :external-format :utf-8)
        (setf manifest (decode-data :json stream))))
    ;; Find data files
    (let ((data-files (if manifest
                          ;; Use manifest to find files
                          (let ((categories-data
                                  (etypecase manifest
                                    (hash-table (gethash "categories" manifest))
                                    (cons (getf manifest :categories)))))
                            (when categories-data
                              (mapcar (lambda (cat-info)
                                        (let ((cat-key (etypecase cat-info
                                                         (hash-table (gethash "category" cat-info))
                                                         (cons (getf cat-info :category))))
                                              (file (etypecase cat-info
                                                      (hash-table (gethash "file" cat-info))
                                                      (cons (getf cat-info :file)))))
                                          (cons (if (keywordp cat-key) cat-key
                                                    (intern (string-upcase
                                                             (substitute #\- #\_ (princ-to-string cat-key)))
                                                            :keyword))
                                                (merge-pathnames file directory))))
                                      (if (vectorp categories-data)
                                          (coerce categories-data 'list)
                                          categories-data))))
                          ;; No manifest - scan directory for data files
                          (scan-backup-directory directory))))
      ;; Restore each file
      (dolist (entry data-files)
        (let ((category (car entry))
              (path (cdr entry)))
          (when (and (probe-file path)
                     (or (null category-filter)
                         (member category category-filter)))
            (let* ((detected-format (if (eq format :auto)
                                        (or (detect-format-from-path path) :json)
                                        format))
                   (raw (with-open-file (stream path :direction :input
                                                      :external-format :utf-8)
                          (decode-data detected-format stream)))
                   (records (extract-backup-data raw)))
              (setf (getf result category) records)))))
      ;; Audit
      (when *audit-enabled-p*
        (let ((total (loop for (nil recs) on result by #'cddr sum (length recs))))
          (record-audit-entry
           (%make-audit-entry
            :event-type :data-backup
            :action :restore
            :status :success
            :details (list :directory (namestring directory)
                           :total-records total
                           :categories-restored
                           (loop for (cat) on result by #'cddr collect cat))))))
      result)))

(defun scan-backup-directory (directory)
  "Scan DIRECTORY for data files and infer categories from filenames.

Returns an alist of (category . pathname)."
  (let ((results '()))
    (dolist (format-name (list-formats))
      (let ((ext (format-extension format-name)))
        (dolist (path (directory (merge-pathnames
                                  (make-pathname :name :wild :type ext)
                                  directory)))
          (unless (string= (pathname-name path) "manifest")
            (let ((category (intern (string-upcase
                                     (substitute #\- #\_ (pathname-name path)))
                                    :keyword)))
              (push (cons category path) results))))))
    (nreverse results)))

(defun extract-backup-data (raw)
  "Extract records from raw parsed backup data.

Handles both bare record lists and metadata-wrapped payloads."
  (let ((normalized (ensure-list-of-plists
                     (typecase raw
                       (hash-table
                        (or (gethash "data" raw) raw))
                       (cons
                        (if (getf raw :data)
                            (getf raw :data)
                            raw))
                       (vector (coerce raw 'list))
                       (t raw)))))
    normalized))

;;; ---------------------------------------------------------------------------
;;; Configuration integration
;;; ---------------------------------------------------------------------------

;; Register data-ops configuration keys
(define-config-key :export-default-format
  :type keyword
  :default :json
  :description "Default data export format"
  :category :data-ops
  :constraints (:one-of (:json :csv :edn :sexp))
  :hot-reload-p t)

(define-config-key :export-directory
  :type (or null string)
  :default nil
  :description "Default directory for data exports"
  :category :data-ops
  :env-var "EVE_GATE_EXPORT_DIR"
  :hot-reload-p t)

(define-config-key :import-directory
  :type (or null string)
  :default nil
  :description "Default directory for data imports"
  :category :data-ops
  :env-var "EVE_GATE_IMPORT_DIR"
  :hot-reload-p t)

(define-config-key :backup-directory
  :type (or null string)
  :default nil
  :description "Default directory for data backups"
  :category :data-ops
  :env-var "EVE_GATE_BACKUP_DIR"
  :hot-reload-p t)

(define-config-key :data-retention-enabled
  :type boolean
  :default t
  :description "Enable automatic data retention policy enforcement"
  :category :data-ops
  :hot-reload-p t)

(define-config-key :privacy-audit-enabled
  :type boolean
  :default t
  :description "Enable privacy audit logging for data operations"
  :category :data-ops
  :hot-reload-p t)

;;; ---------------------------------------------------------------------------
;;; Data operations status and monitoring
;;; ---------------------------------------------------------------------------

(defun data-ops-status (&optional (stream *standard-output*))
  "Print the current data operations status.

STREAM: Output stream"
  (let ((mgr (ensure-data-ops-manager)))
    (format stream "~&=== Data Operations Status ===~%")
    (bt:with-lock-held ((data-ops-manager-lock mgr))
      (format stream "  Default format:   ~A~%" (data-ops-manager-default-format mgr))
      (format stream "  Export directory:  ~A~%"
              (or (data-ops-manager-default-export-dir mgr) "(none)"))
      (format stream "  Import directory:  ~A~%"
              (or (data-ops-manager-default-import-dir mgr) "(none)"))
      (format stream "~%  Active jobs:      ~D~%"
              (hash-table-count (data-ops-manager-active-jobs mgr)))
      (format stream "  Completed jobs:   ~D (retained)~%"
              (length (data-ops-manager-completed-jobs mgr)))
      (format stream "  Total exports:    ~D~%" (data-ops-manager-total-exports mgr))
      (format stream "  Total imports:    ~D~%" (data-ops-manager-total-imports mgr)))
    ;; Format registry
    (format stream "~%  Available formats: ~{~A~^, ~}~%" (list-formats))
    ;; Privacy status
    (format stream "  Privacy audit:    ~A~%" (if *audit-enabled-p* "enabled" "disabled"))
    ;; Retention policies
    (let ((policy-count 0))
      (bt:with-lock-held (*retention-policies-lock*)
        (setf policy-count (hash-table-count *retention-policies*)))
      (format stream "  Retention policies: ~D registered~%" policy-count))
    (format stream "=== End Data Ops Status ===~%"))
  (values))

(defun data-ops-metrics ()
  "Return a plist of data operations metrics for monitoring.

Returns a plist with operational metrics."
  (let ((mgr (ensure-data-ops-manager)))
    (bt:with-lock-held ((data-ops-manager-lock mgr))
      (list :total-exports (data-ops-manager-total-exports mgr)
            :total-imports (data-ops-manager-total-imports mgr)
            :active-jobs (hash-table-count (data-ops-manager-active-jobs mgr))
            :completed-jobs-retained (length (data-ops-manager-completed-jobs mgr))
            :available-formats (list-formats)
            :default-format (data-ops-manager-default-format mgr)))))

;;; ---------------------------------------------------------------------------
;;; Convenience functions for common workflows
;;; ---------------------------------------------------------------------------

(defun quick-export (records &key (format :json) (pretty t))
  "Quick in-memory export for REPL use. Returns a string.

RECORDS: Data to export
FORMAT: Output format (default: :json)
PRETTY: Pretty-print (default: T)"
  (encode-to-string
   (ensure-list-of-plists records) format :pretty pretty))

(defun quick-import (string &key (format :auto))
  "Quick in-memory import for REPL use. Returns a list of plists.

STRING: Encoded data
FORMAT: Input format (default: :auto)"
  (ensure-list-of-plists
   (decode-from-string string
                       (if (eq format :auto)
                           (detect-format-from-content string)
                           format))))

(defun round-trip-test (records &key (format :json))
  "Test that data survives an export/import round trip.

RECORDS: Test data
FORMAT: Format to test

Returns (VALUES success-p original-count round-trip-count)."
  (let* ((exported (encode-to-string records format :pretty nil))
         (imported (decode-from-string exported format))
         (normalized (ensure-list-of-plists imported)))
    (values (= (length (ensure-list-of-plists records))
               (length normalized))
            (length (ensure-list-of-plists records))
            (length normalized))))

;;; ---------------------------------------------------------------------------
;;; Combined initialization
;;; ---------------------------------------------------------------------------

(defun initialize-data-exchange (&key (default-format :json)
                                        export-directory
                                        import-directory
                                        backup-directory)
  "Initialize the complete data exchange subsystem.

Sets up the data operations manager, ensures format handlers are registered,
and configures default directories.

DEFAULT-FORMAT: Default export format (default: :json)
EXPORT-DIRECTORY: Default export directory
IMPORT-DIRECTORY: Default import directory
BACKUP-DIRECTORY: Default backup directory (used as fallback export dir)

Returns the data-ops-manager instance."
  ;; Initialize the manager
  (initialize-data-ops :default-format default-format
                        :default-export-dir (or export-directory backup-directory)
                        :default-import-dir import-directory)
  ;; Ensure audit logging is available
  (ensure-audit-trail)
  ;; Log initialization
  (log-info "Data exchange subsystem initialized: ~D formats, default ~A"
            (length (list-formats)) default-format)
  *data-ops-manager*)
