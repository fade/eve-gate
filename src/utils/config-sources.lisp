;;;; config-sources.lisp - Multiple configuration sources for eve-gate
;;;;
;;;; Provides the "where do values come from" layer of configuration.
;;;; Configuration can be loaded from multiple sources, each with a defined
;;;; precedence. Sources are composable: you can use just environment variables
;;;; for simple deployment, or stack file + env + overrides for complex setups.
;;;;
;;;; Source precedence (highest wins):
;;;;   1. Programmatic overrides (passed directly to the config manager)
;;;;   2. Environment variables (EVE_GATE_* prefix)
;;;;   3. Configuration files (JSON format)
;;;;   4. Schema defaults (from configuration.lisp)
;;;;
;;;; Each source is a function (source-fn) -> plist that reads its values
;;;; and returns a configuration fragment. The config-manager merges these
;;;; fragments in precedence order.
;;;;
;;;; Thread safety: Source reading is inherently read-only. Environment
;;;; variables and files are read once at load time; hot-reload reads
;;;; file sources again under the config-manager's lock.

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Source protocol
;;; ---------------------------------------------------------------------------

(defstruct (config-source (:constructor make-config-source))
  "A named configuration source that can produce key-value pairs.

Slots:
  NAME: Human-readable name for this source
  PRIORITY: Integer priority (higher = takes precedence)
  READER-FN: Function () -> plist that reads current values from this source
  DESCRIPTION: Documentation string
  RELOADABLE-P: Whether this source supports re-reading"
  (name :unknown :type keyword)
  (priority 0 :type integer)
  (reader-fn (constantly nil) :type function)
  (description "" :type string)
  (reloadable-p nil :type boolean))

;;; ---------------------------------------------------------------------------
;;; Environment variable source
;;; ---------------------------------------------------------------------------

(defun parse-env-value (string-value schema-entry)
  "Parse a string value from an environment variable into the appropriate type
based on the schema entry.

STRING-VALUE: The raw string from the environment
SCHEMA-ENTRY: The config-schema-entry for this key

Returns the parsed value."
  (when (and string-value (plusp (length string-value)))
    (let ((target-type (config-schema-entry-type schema-entry)))
      (cond
        ;; Boolean
        ((or (eq target-type 'boolean)
             (equal target-type '(member t nil)))
         (member (string-downcase string-value)
                 '("true" "1" "yes" "t" "on")
                 :test #'string=))
        ;; Integer types
        ((or (eq target-type 'integer)
             (and (listp target-type) (eq (first target-type) 'integer)))
         (parse-integer string-value :junk-allowed t))
        ;; Keyword
        ((eq target-type 'keyword)
         (intern (string-upcase string-value) :keyword))
        ;; String or anything else
        (t string-value)))))

(defun read-env-config (&key (prefix "EVE_GATE_"))
  "Read configuration from environment variables using the schema's env-var mappings.
Only reads keys that have an :env-var defined in their schema entry.

PREFIX: Environment variable prefix (default: \"EVE_GATE_\")
        This is used for auto-mapped keys without explicit env-var names.

Returns a plist of configuration values found in the environment."
  (declare (ignore prefix))
  (let ((config '()))
    (maphash (lambda (key schema-entry)
               (when-let ((env-var (config-schema-entry-env-var schema-entry)))
                 (when-let ((raw-value (uiop:getenv env-var)))
                   (when (plusp (length raw-value))
                     (let ((parsed (parse-env-value raw-value schema-entry)))
                       (when parsed
                         (setf (getf config key) parsed)))))))
             *config-schema*)
    config))

(defun make-env-source (&key (prefix "EVE_GATE_"))
  "Create a configuration source that reads from environment variables.

PREFIX: Environment variable prefix (default: \"EVE_GATE_\")

Returns a CONFIG-SOURCE struct."
  (make-config-source
   :name :environment
   :priority 80
   :reader-fn (lambda () (read-env-config :prefix prefix))
   :description (format nil "Environment variables with prefix ~A" prefix)
   :reloadable-p t))

;;; ---------------------------------------------------------------------------
;;; JSON file source
;;; ---------------------------------------------------------------------------

(defun read-json-config-file (path)
  "Read a JSON configuration file and return it as a configuration plist.
The JSON file should contain an object with string keys that correspond
to configuration keywords (with or without the colon prefix).

PATH: Pathname or string path to the JSON file

Returns a plist of configuration values, or NIL if the file doesn't exist.

Signals an error if the file exists but cannot be parsed.

Example JSON file:
  {
    \"esi-base-url\": \"https://esi.evetech.net\",
    \"default-timeout\": 30,
    \"log-level\": \"info\",
    \"cache-enabled\": true
  }"
  (let ((file-path (pathname path)))
    (unless (probe-file file-path)
      (return-from read-json-config-file nil))
    (handler-case
        (let* ((content (uiop:read-file-string file-path))
               (parsed (com.inuoe.jzon:parse content)))
          (unless (hash-table-p parsed)
            (error "Configuration file ~A does not contain a JSON object" path))
          (json-hash-to-config-plist parsed))
      (error (e)
        (error "Failed to read configuration file ~A: ~A" path e)))))

(defun json-hash-to-config-plist (hash-table)
  "Convert a JSON hash-table (string keys) to a configuration plist (keyword keys).
Handles type coercion for common JSON-to-Lisp mappings:
  - JSON strings that look like keywords (e.g., \"info\") are converted to keywords
    when the schema expects a keyword type
  - JSON booleans map to T/NIL
  - JSON numbers map to integers or floats as appropriate

HASH-TABLE: A hash-table with string keys from JSON parsing

Returns a plist with keyword keys."
  (let ((config '()))
    (maphash (lambda (json-key json-value)
               (let* ((key (json-key-to-keyword json-key))
                      (schema (gethash key *config-schema*))
                      (value (if schema
                                 (coerce-json-config-value json-value schema)
                                 json-value)))
                 (setf (getf config key) value)))
             hash-table)
    config))

(defun json-key-to-keyword (string)
  "Convert a JSON key string to a configuration keyword.
Handles both \"esi-base-url\" and \"esi_base_url\" formats.

STRING: A JSON key string

Returns a keyword symbol."
  (intern (string-upcase (substitute #\- #\_ string)) :keyword))

(defun coerce-json-config-value (json-value schema-entry)
  "Coerce a JSON value to the type expected by the schema entry.

JSON-VALUE: Raw value from JSON parsing
SCHEMA-ENTRY: The config-schema-entry describing the expected type

Returns the coerced value."
  (let ((target-type (config-schema-entry-type schema-entry)))
    (cond
      ;; NIL / null
      ((null json-value) nil)
      ;; JSON string -> keyword when schema expects keyword
      ((and (stringp json-value) (eq target-type 'keyword))
       (intern (string-upcase json-value) :keyword))
      ;; JSON boolean -> CL boolean
      ((eq json-value t) t)
      ((eq json-value nil) nil)
      ;; JSON number -> integer when schema expects integer
      ((and (numberp json-value)
            (or (eq target-type 'integer)
                (and (listp target-type) (eq (first target-type) 'integer))))
       (truncate json-value))
      ;; Pass through
      (t json-value))))

(defun make-file-source (path &key (priority 50))
  "Create a configuration source that reads from a JSON file.

PATH: Path to the JSON configuration file
PRIORITY: Source priority (default: 50)

Returns a CONFIG-SOURCE struct."
  (make-config-source
   :name :file
   :priority priority
   :reader-fn (lambda () (read-json-config-file path))
   :description (format nil "JSON file: ~A" path)
   :reloadable-p t))

;;; ---------------------------------------------------------------------------
;;; Lisp file source (S-expression config)
;;; ---------------------------------------------------------------------------

(defun read-lisp-config-file (path)
  "Read a Lisp configuration file that should contain a plist.
The file should contain a single S-expression that evaluates to a plist.

PATH: Pathname or string path to the Lisp file

Returns a plist of configuration values, or NIL if the file doesn't exist."
  (let ((file-path (pathname path)))
    (unless (probe-file file-path)
      (return-from read-lisp-config-file nil))
    (handler-case
        (with-open-file (stream file-path :direction :input)
          (let ((*read-eval* nil))
            (read stream)))
      (error (e)
        (error "Failed to read Lisp configuration file ~A: ~A" path e)))))

(defun make-lisp-file-source (path &key (priority 50))
  "Create a configuration source that reads from a Lisp plist file.

PATH: Path to the Lisp configuration file
PRIORITY: Source priority (default: 50)

Returns a CONFIG-SOURCE struct."
  (make-config-source
   :name :lisp-file
   :priority priority
   :reader-fn (lambda () (read-lisp-config-file path))
   :description (format nil "Lisp file: ~A" path)
   :reloadable-p t))

;;; ---------------------------------------------------------------------------
;;; Programmatic override source
;;; ---------------------------------------------------------------------------

(defun make-plist-source (plist &key (name :override) (priority 100))
  "Create a configuration source from a static property list.
Useful for programmatic overrides that take highest precedence.

PLIST: Property list of configuration values
NAME: Source name keyword (default: :override)
PRIORITY: Source priority (default: 100, highest)

Returns a CONFIG-SOURCE struct."
  (make-config-source
   :name name
   :priority priority
   :reader-fn (lambda () (copy-list plist))
   :description "Programmatic override"
   :reloadable-p nil))

;;; ---------------------------------------------------------------------------
;;; Source composition and merging
;;; ---------------------------------------------------------------------------

(defun read-all-sources (sources)
  "Read values from all configuration sources, sorted by priority.
Returns a merged plist where higher-priority sources override lower ones.

SOURCES: List of CONFIG-SOURCE structs

Returns a plist."
  (let ((sorted (sort (copy-list sources) #'< :key #'config-source-priority))
        (result (copy-list *default-config*)))
    (dolist (source sorted result)
      (handler-case
          (let ((fragment (funcall (config-source-reader-fn source))))
            (when fragment
              (loop for (key value) on fragment by #'cddr
                    do (setf (getf result key) value))))
        (error (e)
          (log-warn "Failed to read config source ~A: ~A"
                    (config-source-name source) e))))))

(defun reload-sources (sources)
  "Re-read all reloadable configuration sources and merge.
Non-reloadable sources use their last-read values.

SOURCES: List of CONFIG-SOURCE structs

Returns a plist."
  (let ((reloadable (remove-if-not #'config-source-reloadable-p sources))
        (static (remove-if #'config-source-reloadable-p sources)))
    ;; Read static sources normally, they haven't changed
    (read-all-sources (append static reloadable))))

;;; ---------------------------------------------------------------------------
;;; Source discovery utilities
;;; ---------------------------------------------------------------------------

(defun find-config-files (&key (directories nil) (names '("eve-gate" "config")))
  "Search for configuration files in standard locations.
Returns a list of existing file paths.

DIRECTORIES: Additional directories to search (prepended to defaults)
NAMES: Base filenames to look for (without extension)

Searches in order:
  1. User-supplied directories
  2. Current directory
  3. User config directory (~/.config/eve-gate/)"
  (let ((search-dirs (append directories
                             (list (uiop:getcwd)
                                   (merge-pathnames
                                    (make-pathname :directory '(:relative ".config" "eve-gate"))
                                    (user-homedir-pathname)))))
        (extensions '("json" "lisp"))
        (found '()))
    (dolist (dir search-dirs (nreverse found))
      (dolist (name names)
        (dolist (ext extensions)
          (let ((path (merge-pathnames
                       (make-pathname :name name :type ext)
                       (pathname dir))))
            (when (probe-file path)
              (push path found))))))))

(defun auto-discover-sources (&key extra-dirs environment)
  "Automatically discover and create configuration sources from standard locations.
Returns a list of CONFIG-SOURCE structs in priority order.

EXTRA-DIRS: Additional directories to search for config files
ENVIRONMENT: Environment profile to include (:development, :staging, :production)

Source priority (low to high):
  20: Discovered config files
  50: Environment-specific config file
  80: Environment variables
  90: Environment profile overlay"
  (let ((sources '()))
    ;; Discovered config files (lowest priority)
    (dolist (path (find-config-files :directories extra-dirs))
      (let ((ext (pathname-type path)))
        (push (if (string-equal ext "json")
                  (make-file-source path :priority 20)
                  (make-lisp-file-source path :priority 20))
              sources)))
    ;; Environment-specific config file
    (when environment
      (let ((env-name (string-downcase (symbol-name environment))))
        (dolist (path (find-config-files :names (list env-name)))
          (let ((ext (pathname-type path)))
            (push (if (string-equal ext "json")
                      (make-file-source path :priority 50)
                      (make-lisp-file-source path :priority 50))
                  sources)))))
    ;; Environment variables
    (push (make-env-source) sources)
    ;; Environment profile overlay
    (when environment
      (when-let ((env-config (getf *environment-configs* environment)))
        (push (make-plist-source env-config :name :environment-profile :priority 90)
              sources)))
    (nreverse sources)))
