;;;; config-manager.lisp - Centralized configuration management for eve-gate
;;;;
;;;; The configuration manager is the orchestration layer that ties together
;;;; schema validation, multiple sources, subsystem integration, and runtime
;;;; management. It provides:
;;;;
;;;;   - A centralized registry holding the active configuration
;;;;   - Source management (add, remove, re-read sources)
;;;;   - Hot-reload with change detection and validation
;;;;   - Configuration snapshots and rollback
;;;;   - Export and backup utilities
;;;;   - REPL-friendly inspection and management
;;;;
;;;; The config-manager is a singleton accessed through *config-manager*.
;;;; It is thread-safe: reads are lock-free against the current snapshot,
;;;; writes (reload, update) are serialized by a lock.
;;;;
;;;; Lifecycle:
;;;;   1. (initialize-config-manager :environment :production ...)
;;;;   2. Config manager reads all sources, validates, applies
;;;;   3. Runtime: (config-get :key) for reads, (config-update :key value) for writes
;;;;   4. Hot-reload: (reload-config) re-reads sources and applies changes
;;;;   5. Shutdown: (shutdown-config-manager)

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Config manager structure
;;; ---------------------------------------------------------------------------

(defstruct (config-manager (:constructor %make-config-manager))
  "Centralized configuration management singleton.

Slots:
  LOCK: Read-write lock for configuration mutations
  ACTIVE-CONFIG: The currently active configuration plist
  SUBSYSTEM-CONFIG: Pre-extracted subsystem configuration struct
  SOURCES: List of CONFIG-SOURCE structs in priority order
  ENVIRONMENT: Active environment profile keyword
  SNAPSHOTS: List of (timestamp config) pairs for rollback
  MAX-SNAPSHOTS: Maximum number of snapshots to retain
  CHANGE-HOOKS: List of functions called on configuration changes
  INITIALIZED-P: Whether the manager has been initialized
  LAST-RELOAD-TIME: Universal time of last configuration reload"
  (lock (bt:make-lock "config-manager-lock"))
  (active-config nil :type list)
  (subsystem-config nil :type (or null subsystem-config))
  (sources nil :type list)
  (environment nil :type (or null keyword))
  (snapshots nil :type list)
  (max-snapshots 10 :type (integer 1 100))
  (change-hooks nil :type list)
  (initialized-p nil :type boolean)
  (last-reload-time 0 :type integer))

(defvar *config-manager* nil
  "The global configuration manager singleton.
Initialized by INITIALIZE-CONFIG-MANAGER.")

;;; ---------------------------------------------------------------------------
;;; Initialization
;;; ---------------------------------------------------------------------------

(defun initialize-config-manager (&key environment sources config-files
                                       overlay (max-snapshots 10)
                                       (auto-discover t) (validate t))
  "Initialize the global configuration manager.

ENVIRONMENT: Environment profile (:development, :staging, :production)
SOURCES: Explicit list of CONFIG-SOURCE structs
CONFIG-FILES: List of file paths to load as config sources
OVERLAY: Plist of highest-priority programmatic overrides
MAX-SNAPSHOTS: Maximum configuration snapshots to retain (default: 10)
AUTO-DISCOVER: When T, search standard locations for config files (default: T)
VALIDATE: When T, validate the merged configuration (default: T)

Returns the initialized config manager."
  ;; Build source list
  (let ((all-sources '()))
    ;; Auto-discovered sources
    (when auto-discover
      (setf all-sources (auto-discover-sources
                         :environment environment)))
    ;; Explicit config files
    (dolist (path config-files)
      (let ((ext (pathname-type (pathname path))))
        (push (if (string-equal ext "json")
                  (make-file-source path :priority 60)
                  (make-lisp-file-source path :priority 60))
              all-sources)))
    ;; Explicit sources
    (when sources
      (setf all-sources (append all-sources sources)))
    ;; Programmatic overlay (highest priority)
    (when overlay
      (push (make-plist-source overlay) all-sources))
    ;; Read and merge all sources
    (let* ((merged-config (read-all-sources all-sources))
           (manager (%make-config-manager
                     :active-config merged-config
                     :sources all-sources
                     :environment environment
                     :max-snapshots max-snapshots
                     :initialized-p t
                     :last-reload-time (get-universal-time))))
      ;; Validate if requested
      (when validate
        (multiple-value-bind (valid-p errors)
            (validate-config merged-config
                             :environment environment
                             :collect-errors t)
          (when errors
            (dolist (err errors)
              (log-warn "Configuration validation: ~A" err))
            (unless valid-p
              (log-error "Configuration has ~D validation errors" (length errors))))))
      ;; Apply configuration to subsystems
      (setf (config-manager-subsystem-config manager)
            (apply-config merged-config))
      ;; Set the global manager and environment
      (setf *config-manager* manager)
      (when environment
        (setf *current-environment* environment))
      ;; Log initialization
      (log-event :info "Configuration manager initialized"
                 :source :config
                 :environment environment
                 :sources (length all-sources)
                 :keys (length (config-keys merged-config)))
      manager)))

(defun ensure-config-manager ()
  "Ensure the configuration manager is initialized.
Creates a default manager if none exists.

Returns the config manager."
  (or *config-manager*
      (initialize-config-manager)))

(defun shutdown-config-manager ()
  "Shut down the configuration manager and release resources."
  (when *config-manager*
    (log-event :info "Configuration manager shutting down" :source :config)
    (setf *config-manager* nil)
    t))

;;; ---------------------------------------------------------------------------
;;; Configuration access API
;;; ---------------------------------------------------------------------------

(defun config-get (key &optional default)
  "Get a configuration value from the active configuration.
This is the primary read API for subsystems.

KEY: Configuration keyword
DEFAULT: Value to return if key is not found (default: schema default)

Returns the configuration value.

Example:
  (config-get :default-timeout) => 30
  (config-get :client-id) => NIL"
  (let ((manager (ensure-config-manager)))
    (let ((config (config-manager-active-config manager)))
      (multiple-value-bind (indicator value tail)
          (get-properties config (list key))
        (declare (ignore indicator))
        (if tail
            value
            (or default
                (let ((schema (gethash key *config-schema*)))
                  (when schema
                    (config-schema-entry-default schema)))))))))

(defun config-set (key value)
  "Set a configuration value in the active configuration.
Only allows setting hot-reloadable keys at runtime.
For non-hot-reloadable keys, signals an error.

KEY: Configuration keyword
VALUE: New value (validated against schema)

Returns VALUE."
  (let ((manager (ensure-config-manager)))
    ;; Validate the key is hot-reloadable
    (let ((schema (gethash key *config-schema*)))
      (when (and schema (not (config-schema-entry-hot-reload-p schema)))
        (error "Configuration key ~A is not hot-reloadable. ~
                Restart required to change this setting." key)))
    ;; Validate the value
    (validate-config-value key value)
    ;; Apply under lock
    (bt:with-lock-held ((config-manager-lock manager))
      (let ((old-value (getf (config-manager-active-config manager) key)))
        ;; Take snapshot before change
        (push-config-snapshot manager)
        ;; Set the value
        (setf (getf (config-manager-active-config manager) key) value)
        ;; Re-apply relevant subsystem config
        (apply-config (config-manager-active-config manager) :hot-reload t)
        (setf (config-manager-subsystem-config manager)
              (extract-subsystem-config (config-manager-active-config manager)))
        ;; Notify change hooks
        (run-change-hooks manager (list (list key old-value value)))
        ;; Log the change
        (log-event :info "Configuration value changed"
                   :source :config
                   :key key
                   :old-value old-value
                   :new-value value)))
    value))

(defun config-getf (key &optional default)
  "Alias for CONFIG-GET. Mnemonic: 'get from' configuration.

KEY: Configuration keyword
DEFAULT: Fallback value"
  (config-get key default))

;;; ---------------------------------------------------------------------------
;;; Bulk configuration operations
;;; ---------------------------------------------------------------------------

(defun config-update (updates &key (validate t))
  "Apply multiple configuration updates atomically.

UPDATES: Plist of key-value pairs to update
VALIDATE: When T, validate all values before applying (default: T)

Returns the number of keys updated."
  (let ((manager (ensure-config-manager)))
    ;; Validate all values first
    (when validate
      (loop for (key value) on updates by #'cddr
            do (validate-config-value key value)
               (let ((schema (gethash key *config-schema*)))
                 (when (and schema (not (config-schema-entry-hot-reload-p schema)))
                   (log-warn "Config key ~A is not hot-reloadable, skipping" key)))))
    ;; Apply under lock
    (bt:with-lock-held ((config-manager-lock manager))
      (push-config-snapshot manager)
      (let ((changes '())
            (count 0))
        (loop for (key value) on updates by #'cddr
              do (let ((schema (gethash key *config-schema*)))
                   (when (or (null schema) (config-schema-entry-hot-reload-p schema))
                     (let ((old-value (getf (config-manager-active-config manager) key)))
                       (unless (equal old-value value)
                         (setf (getf (config-manager-active-config manager) key) value)
                         (push (list key old-value value) changes)
                         (incf count))))))
        ;; Re-apply configuration
        (when (plusp count)
          (apply-config (config-manager-active-config manager) :hot-reload t)
          (setf (config-manager-subsystem-config manager)
                (extract-subsystem-config (config-manager-active-config manager)))
          (run-change-hooks manager changes)
          (log-event :info "Bulk configuration update"
                     :source :config
                     :keys-updated count))
        count))))

;;; ---------------------------------------------------------------------------
;;; Hot reload
;;; ---------------------------------------------------------------------------

(defun reload-config (&key (validate t))
  "Re-read all reloadable configuration sources and apply changes.
Takes a snapshot before applying for rollback capability.

VALIDATE: When T, validate the new configuration before applying

Returns the number of changes applied."
  (let ((manager (ensure-config-manager)))
    (bt:with-lock-held ((config-manager-lock manager))
      (let* ((old-config (copy-list (config-manager-active-config manager)))
             (new-config (reload-sources (config-manager-sources manager))))
        ;; Validate new config
        (when validate
          (multiple-value-bind (valid-p errors)
              (validate-config new-config
                               :environment (config-manager-environment manager)
                               :collect-errors t)
            (declare (ignore valid-p))
            (when errors
              (log-warn "Configuration reload has ~D validation issues"
                        (length errors)))))
        ;; Compute changes
        (let ((changes (config-changes old-config new-config)))
          (when changes
            ;; Snapshot before applying
            (push-config-snapshot manager)
            ;; Apply the new configuration
            (setf (config-manager-active-config manager) new-config)
            (apply-config new-config :hot-reload t)
            (setf (config-manager-subsystem-config manager)
                  (extract-subsystem-config new-config))
            (setf (config-manager-last-reload-time manager)
                  (get-universal-time))
            ;; Log and notify
            (log-config-changes changes)
            (run-change-hooks manager changes))
          (length changes))))))

;;; ---------------------------------------------------------------------------
;;; Snapshots and rollback
;;; ---------------------------------------------------------------------------

(defun push-config-snapshot (manager)
  "Take a snapshot of the current configuration for rollback.
Trims old snapshots if over the maximum.

MANAGER: The config-manager struct"
  (push (list (get-universal-time)
              (copy-list (config-manager-active-config manager)))
        (config-manager-snapshots manager))
  ;; Trim to max
  (when (> (length (config-manager-snapshots manager))
           (config-manager-max-snapshots manager))
    (setf (config-manager-snapshots manager)
          (subseq (config-manager-snapshots manager)
                  0 (config-manager-max-snapshots manager)))))

(defun config-rollback (&optional (steps 1))
  "Roll back the configuration to a previous snapshot.

STEPS: Number of snapshots to roll back (default: 1)

Returns T if rollback was successful, NIL if no snapshot available."
  (let ((manager (ensure-config-manager)))
    (bt:with-lock-held ((config-manager-lock manager))
      (let ((snapshots (config-manager-snapshots manager)))
        (when (and snapshots (>= (length snapshots) steps))
          (let ((snapshot (nth (1- steps) snapshots)))
            (setf (config-manager-active-config manager) (copy-list (second snapshot)))
            (apply-config (config-manager-active-config manager) :hot-reload t)
            (setf (config-manager-subsystem-config manager)
                  (extract-subsystem-config (config-manager-active-config manager)))
            ;; Remove used snapshots
            (setf (config-manager-snapshots manager)
                  (nthcdr steps snapshots))
            (log-event :info "Configuration rolled back"
                       :source :config
                       :steps steps
                       :snapshot-time (first snapshot))
            t))))))

(defun config-snapshots ()
  "Return a list of available configuration snapshots.
Each entry is (TIMESTAMP CONFIG-PLIST)."
  (when *config-manager*
    (config-manager-snapshots *config-manager*)))

;;; ---------------------------------------------------------------------------
;;; Change hooks
;;; ---------------------------------------------------------------------------

(defun add-config-change-hook (name function)
  "Register a function to be called when configuration changes.

NAME: Keyword name for this hook (for later removal)
FUNCTION: Function (changes) where changes is a list of (KEY OLD NEW) triples"
  (let ((manager (ensure-config-manager)))
    (bt:with-lock-held ((config-manager-lock manager))
      ;; Remove existing hook with same name
      (setf (config-manager-change-hooks manager)
            (remove name (config-manager-change-hooks manager)
                    :key #'car))
      (push (cons name function)
            (config-manager-change-hooks manager)))))

(defun remove-config-change-hook (name)
  "Remove a named configuration change hook.

NAME: The keyword name given when the hook was added"
  (when *config-manager*
    (bt:with-lock-held ((config-manager-lock *config-manager*))
      (setf (config-manager-change-hooks *config-manager*)
            (remove name (config-manager-change-hooks *config-manager*)
                    :key #'car)))))

(defun run-change-hooks (manager changes)
  "Run all registered change hooks with the given CHANGES.

MANAGER: The config-manager struct
CHANGES: List of (KEY OLD-VALUE NEW-VALUE) triples"
  (dolist (hook (config-manager-change-hooks manager))
    (handler-case
        (funcall (cdr hook) changes)
      (error (e)
        (log-error "Config change hook ~A failed: ~A" (car hook) e)))))

;;; ---------------------------------------------------------------------------
;;; Export and backup
;;; ---------------------------------------------------------------------------

(defun export-config (&key (format :json) (stream *standard-output*)
                           (include-defaults nil) (include-sensitive nil))
  "Export the active configuration.

FORMAT: Output format (:json, :lisp, :env)
STREAM: Output stream (default: *standard-output*)
INCLUDE-DEFAULTS: Include keys with default values (default: NIL)
INCLUDE-SENSITIVE: Include sensitive keys like client-secret (default: NIL)

Returns the number of keys exported."
  (let* ((manager (ensure-config-manager))
         (config (config-manager-active-config manager))
         (sensitive-keys '(:client-secret :database-url))
         (count 0))
    (ecase format
      (:json
       (format stream "{~%")
       (let ((emitted-first nil))
         (loop for (key value) on config by #'cddr
               do (let ((schema (gethash key *config-schema*)))
                    (when (and (or include-defaults
                                   (not (and schema
                                             (equal value
                                                    (config-schema-entry-default schema)))))
                               (or include-sensitive
                                   (not (member key sensitive-keys))))
                      (when emitted-first (format stream ",~%"))
                      (format stream "  ~S: ~A"
                              (string-downcase (substitute #\- #\_ (symbol-name key)))
                              (json-encode-config-value value))
                      (setf emitted-first t)
                      (incf count)))))
       (format stream "~%}~%"))
      (:lisp
       (format stream "(~%")
       (loop for (key value) on config by #'cddr
             do (when (or include-sensitive
                         (not (member key sensitive-keys)))
                  (format stream "  ~S ~S~%" key value)
                  (incf count)))
       (format stream ")~%"))
      (:env
       (maphash (lambda (key schema)
                  (when-let ((env-var (config-schema-entry-env-var schema)))
                    (let ((value (getf config key)))
                      (when (and value
                                 (or include-sensitive
                                     (not (member key sensitive-keys))))
                        (format stream "~A=~A~%" env-var
                                (env-encode-config-value value))
                        (incf count)))))
                *config-schema*)))
    count))

(defun json-encode-config-value (value)
  "Encode a configuration value as a JSON value string.

VALUE: The value to encode

Returns a string."
  (cond
    ((null value) "null")
    ((eq value t) "true")
    ((integerp value) (format nil "~D" value))
    ((floatp value) (format nil "~F" value))
    ((keywordp value) (format nil "~S" (string-downcase (symbol-name value))))
    ((stringp value) (format nil "~S" value))
    (t (format nil "~S" (princ-to-string value)))))

(defun env-encode-config-value (value)
  "Encode a configuration value as an environment variable string.

VALUE: The value to encode

Returns a string."
  (cond
    ((null value) "")
    ((eq value t) "true")
    ((keywordp value) (string-downcase (symbol-name value)))
    (t (princ-to-string value))))

(defun save-config-to-file (path &key (format :json) (include-defaults t))
  "Save the active configuration to a file.

PATH: Output file path
FORMAT: File format (:json or :lisp, default: :json)
INCLUDE-DEFAULTS: Include default values (default: T)

Returns the number of keys written."
  (with-open-file (stream path :direction :output
                               :if-exists :supersede
                               :if-does-not-exist :create)
    (export-config :format format :stream stream
                   :include-defaults include-defaults
                   :include-sensitive nil)))

;;; ---------------------------------------------------------------------------
;;; REPL inspection
;;; ---------------------------------------------------------------------------

(defun config-status (&optional (stream *standard-output*))
  "Print the current configuration manager status.

STREAM: Output stream (default: *standard-output*)"
  (let ((manager *config-manager*))
    (if (null manager)
        (format stream "~&Configuration manager not initialized.~%")
        (progn
          (format stream "~&=== Configuration Manager Status ===~%")
          (format stream "  Environment:    ~A~%"
                  (or (config-manager-environment manager) "(none)"))
          (format stream "  Initialized:    ~A~%" (config-manager-initialized-p manager))
          (format stream "  Active keys:    ~D~%"
                  (length (config-keys (config-manager-active-config manager))))
          (format stream "  Sources:        ~D~%"
                  (length (config-manager-sources manager)))
          (dolist (source (config-manager-sources manager))
            (format stream "    ~A (priority ~D): ~A~%"
                    (config-source-name source)
                    (config-source-priority source)
                    (config-source-description source)))
          (format stream "  Snapshots:      ~D/~D~%"
                  (length (config-manager-snapshots manager))
                  (config-manager-max-snapshots manager))
          (format stream "  Change hooks:   ~D~%"
                  (length (config-manager-change-hooks manager)))
          (format stream "  Last reload:    ~A~%"
                  (if (zerop (config-manager-last-reload-time manager))
                      "(never)"
                      (format-config-timestamp
                       (config-manager-last-reload-time manager))))
          (format stream "=== End Config Status ===~%")))
    (values)))

(defun format-config-timestamp (universal-time)
  "Format a universal time for display in config status."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time universal-time)
    (format nil "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D"
            year month day hour min sec)))

(defun show-active-config (&key (category nil) (stream *standard-output*))
  "Print the active configuration, optionally filtered by category.

CATEGORY: When specified, only show keys in this category
STREAM: Output stream (default: *standard-output*)"
  (let* ((manager (ensure-config-manager))
         (config (config-manager-active-config manager)))
    (format stream "~&=== Active Configuration~@[ (~A)~] ===~%" category)
    (if category
        ;; Show only the specified category
        (dolist (key (config-keys-for-category category))
          (let ((value (getf config key))
                (schema (gethash key *config-schema*)))
            (format stream "  ~A: ~S~@[  (default: ~S)~]~%"
                    key value
                    (when (and schema
                               (not (equal value
                                           (config-schema-entry-default schema))))
                      (config-schema-entry-default schema)))))
        ;; Show all by category
        (dolist (cat (config-categories))
          (format stream "~%  ~A:~%" cat)
          (dolist (key (config-keys-for-category cat))
            (format stream "    ~A: ~S~%" key (getf config key)))))
    (format stream "=== End Config ===~%"))
  (values))
