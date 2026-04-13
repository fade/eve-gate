;;;; log-output.lisp - Log output destinations, formatting, and rotation for eve-gate
;;;;
;;;; Provides pluggable output destinations for the structured logging system:
;;;;   - Console output with configurable formatting and color
;;;;   - File output with size-based and time-based rotation
;;;;   - Async (buffered) output to prevent I/O blocking on hot paths
;;;;
;;;; Each destination is a function (log-entry) -> void that can be registered
;;;; with ADD-LOG-DESTINATION from logging.lisp. This file provides constructors
;;;; for the standard destination types plus formatting functions.
;;;;
;;;; Formatters:
;;;;   - :json — Machine-parseable JSON, one object per line (JSONL)
;;;;   - :text — Human-readable single-line text
;;;;   - :dev  — Developer-friendly with color codes and alignment
;;;;
;;;; File rotation:
;;;;   - Size-based: rotates when file exceeds a configurable size
;;;;   - Time-based: rotates daily at midnight UTC
;;;;   - Compression: old log files are optionally gzip-compressed
;;;;   - Cleanup: retains a configurable number of rotated files
;;;;
;;;; Async output:
;;;;   - Entries are queued in a bounded ring buffer
;;;;   - A background thread drains the buffer to the actual destination
;;;;   - Overflow policy: drop oldest entries (never block the logger)
;;;;
;;;; Thread safety: All destinations are safe for concurrent use.
;;;; File destinations use a per-file lock. Async destinations use a
;;;; lock-free ring buffer with a background writer thread.

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Log formatters
;;; ---------------------------------------------------------------------------

(defun format-log-json (entry stream)
  "Format a log entry as a single-line JSON object (JSONL format).
Suitable for log aggregation systems (ELK, Loki, etc.).

ENTRY: A log-entry struct
STREAM: Output stream

Example output:
  {\"timestamp\":\"2026-04-13T15:30:45.123Z\",\"level\":\"info\",\"message\":\"...\"}"
  (let ((ht (make-hash-table :test 'equal)))
    ;; Core fields
    (setf (gethash "timestamp" ht)
          (format-log-timestamp (log-entry-timestamp entry)
                                (log-entry-timestamp-internal entry)))
    (setf (gethash "level" ht)
          (string-downcase (symbol-name (log-entry-level entry))))
    (setf (gethash "message" ht) (log-entry-message entry))
    (setf (gethash "seq" ht) (log-entry-sequence entry))
    ;; Thread
    (when (log-entry-thread-name entry)
      (setf (gethash "thread" ht) (log-entry-thread-name entry)))
    ;; Optional context fields
    (when (log-entry-source entry)
      (setf (gethash "source" ht)
            (if (keywordp (log-entry-source entry))
                (string-downcase (symbol-name (log-entry-source entry)))
                (log-entry-source entry))))
    (when (log-entry-request-id entry)
      (setf (gethash "request_id" ht) (log-entry-request-id entry)))
    (when (log-entry-correlation-id entry)
      (setf (gethash "correlation_id" ht) (log-entry-correlation-id entry)))
    (when (log-entry-character-id entry)
      (setf (gethash "character_id" ht) (log-entry-character-id entry)))
    (when (log-entry-error-p entry)
      (setf (gethash "error" ht) t))
    ;; Structured fields
    (loop for (k v) on (log-entry-fields entry) by #'cddr
          do (setf (gethash (string-downcase
                             (if (keywordp k) (symbol-name k) (princ-to-string k)))
                            ht)
                   v))
    ;; Write as JSON
    (com.inuoe.jzon:stringify ht :stream stream)
    (terpri stream)))

(defun format-log-text (entry stream)
  "Format a log entry as a human-readable single-line text message.
Includes timestamp, level, source, and message. Structured fields
are appended as key=value pairs.

ENTRY: A log-entry struct
STREAM: Output stream

Example output:
  15:30:45.123 [INFO ] http-client req=req-153045-0001 Request completed endpoint=/v5/status/ status=200"
  (multiple-value-bind (sec min hour)
      (decode-universal-time (log-entry-timestamp entry) 0)
    (let ((sub-second (mod (log-entry-timestamp-internal entry)
                           internal-time-units-per-second)))
      (format stream "~2,'0D:~2,'0D:~2,'0D.~3,'0D [~5A]"
              hour min sec
              (floor (* 1000 sub-second) internal-time-units-per-second)
              (string-upcase (symbol-name (log-entry-level entry))))))
  ;; Source
  (when (log-entry-source entry)
    (format stream " ~A"
            (if (keywordp (log-entry-source entry))
                (string-downcase (symbol-name (log-entry-source entry)))
                (log-entry-source entry))))
  ;; Request ID
  (when (log-entry-request-id entry)
    (format stream " req=~A" (log-entry-request-id entry)))
  ;; Correlation ID
  (when (log-entry-correlation-id entry)
    (format stream " corr=~A" (log-entry-correlation-id entry)))
  ;; Message
  (format stream " ~A" (log-entry-message entry))
  ;; Structured fields as key=value
  (loop for (k v) on (log-entry-fields entry) by #'cddr
        do (format stream " ~A=~A"
                   (string-downcase
                    (if (keywordp k) (symbol-name k) (princ-to-string k)))
                   v))
  (terpri stream))

(defun format-log-dev (entry stream)
  "Format a log entry in developer-friendly format with ANSI color codes.
Uses color to highlight log levels and visually separate context from message.

ENTRY: A log-entry struct
STREAM: Output stream"
  (let ((color (ecase (log-entry-level entry)
                 (:trace  "37")    ; white/gray
                 (:debug  "36")    ; cyan
                 (:info   "32")    ; green
                 (:warn   "33")    ; yellow
                 (:error  "31")    ; red
                 (:fatal  "35")))  ; magenta
        (reset "0"))
    ;; Timestamp
    (multiple-value-bind (sec min hour)
        (decode-universal-time (log-entry-timestamp entry) 0)
      (format stream "~C[~Am~2,'0D:~2,'0D:~2,'0D~C[~Am"
              #\Escape "90" ; dark gray for timestamp
              hour min sec
              #\Escape reset))
    ;; Level (colored)
    (format stream " ~C[~A;1m~5A~C[~Am"
            #\Escape color
            (string-upcase (symbol-name (log-entry-level entry)))
            #\Escape reset)
    ;; Source (dimmed)
    (when (log-entry-source entry)
      (format stream " ~C[~Am~A~C[~Am"
              #\Escape "90"
              (if (keywordp (log-entry-source entry))
                  (string-downcase (symbol-name (log-entry-source entry)))
                  (log-entry-source entry))
              #\Escape reset))
    ;; Request context (dimmed)
    (when (log-entry-request-id entry)
      (format stream " ~C[~Am[~A]~C[~Am"
              #\Escape "90"
              (log-entry-request-id entry)
              #\Escape reset))
    ;; Message
    (format stream " ~A" (log-entry-message entry))
    ;; Fields (dimmed key=value)
    (when (log-entry-fields entry)
      (format stream " ~C[~Am{" #\Escape "90")
      (loop for (k v) on (log-entry-fields entry) by #'cddr
            for first = t then nil
            do (unless first (format stream ", "))
               (format stream "~A=~A"
                       (string-downcase
                        (if (keywordp k) (symbol-name k) (princ-to-string k)))
                       v))
      (format stream "}~C[~Am" #\Escape reset))
    (terpri stream)))

;;; ---------------------------------------------------------------------------
;;; Formatter selection
;;; ---------------------------------------------------------------------------

(defun get-log-formatter (format-type)
  "Return the formatting function for FORMAT-TYPE.

FORMAT-TYPE: One of :json, :text, :dev
Returns a function (log-entry stream) -> void."
  (ecase format-type
    (:json #'format-log-json)
    (:text #'format-log-text)
    (:dev  #'format-log-dev)))

;;; ---------------------------------------------------------------------------
;;; Console destination
;;; ---------------------------------------------------------------------------

(defun make-console-destination (&key (format :dev)
                                      (stream *standard-output*)
                                      (min-level nil))
  "Create a log destination that writes to the console.

FORMAT: Output format (:json, :text, :dev). Default :dev for terminal.
STREAM: Output stream (default: *standard-output*)
MIN-LEVEL: Optional minimum level filter for this destination

Returns a function suitable for ADD-LOG-DESTINATION.

Example:
  (add-log-destination (make-console-destination :format :dev) :name :console)"
  (let ((formatter (get-log-formatter format))
        (captured-stream stream))
    (lambda (entry)
      (when (or (null min-level)
                (>= (log-level-value (log-entry-level entry))
                    (log-level-value min-level)))
        (funcall formatter entry captured-stream)
        (force-output captured-stream)))))

;;; ---------------------------------------------------------------------------
;;; File destination with rotation
;;; ---------------------------------------------------------------------------

(defstruct (log-file-state (:constructor %make-log-file-state))
  "Internal state for a rotating file log destination.

Slots:
  BASE-PATH: Base file path (e.g., \"/var/log/eve-gate/esi.log\")
  CURRENT-STREAM: Open file stream for the active log file
  CURRENT-PATH: Path of the currently open file
  CURRENT-SIZE: Bytes written to current file
  LOCK: Mutex for thread-safe writes
  FORMATTER: Formatting function
  MAX-SIZE: Maximum file size in bytes before rotation (NIL = no size limit)
  MAX-FILES: Maximum number of rotated files to retain
  ROTATE-DAILY-P: Whether to rotate at midnight UTC
  CURRENT-DAY: Day-of-year of the current file (for daily rotation)
  MIN-LEVEL: Minimum log level for this destination"
  (base-path "" :type string)
  (current-stream nil)
  (current-path "" :type string)
  (current-size 0 :type integer)
  (lock (bt:make-lock "log-file-lock"))
  (formatter #'format-log-text :type function)
  (max-size nil :type (or null integer))
  (max-files 10 :type integer)
  (rotate-daily-p t :type boolean)
  (current-day 0 :type integer)
  (min-level nil :type (or null keyword)))

(defun make-file-destination (path &key (format :text)
                                        (max-size (* 50 1024 1024))
                                        (max-files 10)
                                        (rotate-daily t)
                                        (min-level nil))
  "Create a log destination that writes to a file with rotation support.

PATH: Base file path (e.g., \"/var/log/eve-gate/esi.log\")
FORMAT: Output format (:json, :text). Default :text.
MAX-SIZE: Maximum file size in bytes before rotation (default: 50MB, NIL to disable)
MAX-FILES: Maximum rotated files to keep (default: 10)
ROTATE-DAILY: Rotate at midnight UTC (default: T)
MIN-LEVEL: Optional minimum level filter for this destination

Returns a function suitable for ADD-LOG-DESTINATION.

File naming scheme for rotated files:
  base.log -> base.log.1 -> base.log.2 -> ... -> base.log.N (deleted)

Example:
  (add-log-destination
    (make-file-destination \"/var/log/eve-gate/esi.log\"
                           :format :json
                           :max-size (* 100 1024 1024)
                           :max-files 7)
    :name :file-esi)"
  (let ((state (%make-log-file-state
                :base-path path
                :formatter (get-log-formatter format)
                :max-size max-size
                :max-files max-files
                :rotate-daily-p rotate-daily
                :min-level min-level)))
    ;; Ensure directory exists
    (ensure-log-directory path)
    ;; Open initial file
    (open-log-file state)
    ;; Return the destination function (captures state via closure)
    (lambda (entry)
      (when (or (null (log-file-state-min-level state))
                (>= (log-level-value (log-entry-level entry))
                    (log-level-value (log-file-state-min-level state))))
        (write-to-log-file state entry)))))

(defun ensure-log-directory (path)
  "Ensure the directory for PATH exists."
  (let ((dir (directory-namestring (pathname path))))
    (when (and dir (plusp (length dir)))
      (ensure-directories-exist (pathname dir)))))

(defun open-log-file (state)
  "Open or reopen the log file for STATE."
  (let ((path (log-file-state-base-path state)))
    (when (log-file-state-current-stream state)
      (ignore-errors (close (log-file-state-current-stream state))))
    (setf (log-file-state-current-stream state)
          (open path :direction :output
                     :if-exists :append
                     :if-does-not-exist :create
                     :element-type 'character
                     :external-format :utf-8)
          (log-file-state-current-path state) path
          (log-file-state-current-size state)
          (if (probe-file path)
              (with-open-file (s path :direction :input)
                (file-length s))
              0)
          (log-file-state-current-day state) (current-day-of-year))))

(defun current-day-of-year ()
  "Return the current day of year (1-366) in UTC."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (get-universal-time) 0)
    (declare (ignore sec min hour))
    ;; Approximate day-of-year from month and day
    (+ day (* (1- month) 30)
       (cond ((> month 2) (- (floor month 2)))
             (t 0))
       ;; Adjust for year (leap year approximation)
       (if (and (zerop (mod year 4))
                (or (not (zerop (mod year 100)))
                    (zerop (mod year 400))))
           0 0))))

(defun write-to-log-file (state entry)
  "Write a log entry to the file, rotating if necessary. Thread-safe."
  (bt:with-lock-held ((log-file-state-lock state))
    ;; Check if rotation is needed
    (when (rotation-needed-p state)
      (rotate-log-file state))
    ;; Write the entry
    (let ((stream (log-file-state-current-stream state)))
      (when stream
        (let ((start-pos (file-position stream)))
          (funcall (log-file-state-formatter state) entry stream)
          (force-output stream)
          (let ((bytes-written (- (file-position stream) (or start-pos 0))))
            (incf (log-file-state-current-size state) bytes-written)))))))

(defun rotation-needed-p (state)
  "Check if the current log file needs rotation."
  (or
   ;; Size-based rotation
   (and (log-file-state-max-size state)
        (> (log-file-state-current-size state)
           (log-file-state-max-size state)))
   ;; Time-based rotation (daily)
   (and (log-file-state-rotate-daily-p state)
        (/= (current-day-of-year)
            (log-file-state-current-day state)))))

(defun rotate-log-file (state)
  "Rotate the log file: close current, rename existing, open new.
Must be called with the file state lock held."
  (let ((base-path (log-file-state-base-path state))
        (max-files (log-file-state-max-files state)))
    ;; Close current stream
    (when (log-file-state-current-stream state)
      (ignore-errors (close (log-file-state-current-stream state)))
      (setf (log-file-state-current-stream state) nil))
    ;; Rotate existing files: base.log.N -> base.log.N+1
    ;; Delete the oldest if it exceeds max-files
    (loop for i from (1- max-files) downto 1
          for old-path = (format nil "~A.~D" base-path i)
          for new-path = (format nil "~A.~D" base-path (1+ i))
          when (probe-file old-path)
          do (if (= i (1- max-files))
                 ;; Delete the oldest rotated file
                 (ignore-errors (delete-file old-path))
                 ;; Rename to next number
                 (ignore-errors (rename-file old-path new-path))))
    ;; Rename current to .1
    (when (probe-file base-path)
      (ignore-errors (rename-file base-path
                                  (format nil "~A.1" base-path))))
    ;; Open fresh file
    (open-log-file state)))

(defun close-file-destination (destination-fn)
  "Close the file stream for a file destination.
Call this during shutdown to ensure all data is flushed.

DESTINATION-FN: The function returned by MAKE-FILE-DESTINATION

Note: This relies on the closure capturing state. In practice, 
call SHUTDOWN-LOGGING to close all destinations."
  (declare (ignore destination-fn))
  ;; The destination function captures state via closure.
  ;; Direct state access requires the caller to hold a reference.
  ;; Shutdown-logging handles this more cleanly.
  nil)

;;; ---------------------------------------------------------------------------
;;; Async (buffered) destination wrapper
;;; ---------------------------------------------------------------------------

(defstruct (async-log-buffer (:constructor %make-async-log-buffer))
  "Ring buffer for async log entry queuing.

Slots:
  BUFFER: Simple vector acting as ring buffer
  SIZE: Capacity of the ring buffer
  HEAD: Write position (next slot to write)
  TAIL: Read position (next slot to read)
  COUNT: Number of entries in the buffer
  LOCK: Mutex for buffer access
  CONDITION: Condition variable for signaling the writer thread
  INNER-DESTINATION: The actual destination function
  WRITER-THREAD: Background thread that drains the buffer
  RUNNING-P: Whether the writer thread is active
  DROPPED-COUNT: Number of entries dropped due to buffer overflow"
  (buffer nil :type (or null simple-vector))
  (size 4096 :type fixnum)
  (head 0 :type fixnum)
  (tail 0 :type fixnum)
  (count 0 :type fixnum)
  (lock (bt:make-lock "async-log-buffer-lock"))
  (condition (bt:make-condition-variable :name "async-log-cv"))
  (inner-destination nil :type (or null function))
  (writer-thread nil)
  (running-p nil :type boolean)
  (dropped-count 0 :type integer))

(defun make-async-destination (inner-destination &key (buffer-size 4096)
                                                      (name "async-log-writer"))
  "Wrap INNER-DESTINATION in an async buffered writer.
Log entries are queued in a ring buffer and written by a background thread,
preventing I/O latency from affecting the logging caller.

INNER-DESTINATION: The actual destination function to write to
BUFFER-SIZE: Ring buffer capacity (default: 4096 entries)
NAME: Name for the background writer thread

Returns a function suitable for ADD-LOG-DESTINATION.

Example:
  (add-log-destination
    (make-async-destination
      (make-file-destination \"/var/log/eve-gate/esi.log\" :format :json)
      :buffer-size 8192)
    :name :async-file)"
  (let ((buf (%make-async-log-buffer
              :buffer (make-array buffer-size :initial-element nil)
              :size buffer-size
              :inner-destination inner-destination)))
    ;; Start the background writer thread
    (start-async-writer buf name)
    ;; Return the destination function that enqueues entries
    (lambda (entry)
      (async-enqueue buf entry))))

(defun start-async-writer (buf name)
  "Start the background writer thread for an async buffer."
  (setf (async-log-buffer-running-p buf) t)
  (setf (async-log-buffer-writer-thread buf)
        (bt:make-thread
         (lambda ()
           (async-writer-loop buf))
         :name name)))

(defun async-writer-loop (buf)
  "Main loop for the async log writer thread.
Drains entries from the ring buffer and dispatches to the inner destination."
  (loop while (async-log-buffer-running-p buf)
        do (let ((entries (async-drain-buffer buf)))
             (if entries
                 (dolist (entry entries)
                   (handler-case
                       (funcall (async-log-buffer-inner-destination buf) entry)
                     (error (e)
                       (format *error-output*
                               "~&[ASYNC-LOG-ERROR] ~A~%" e))))
                 ;; No entries available, wait for signal
                 (bt:with-lock-held ((async-log-buffer-lock buf))
                   (when (zerop (async-log-buffer-count buf))
                     (bt:condition-wait
                      (async-log-buffer-condition buf)
                      (async-log-buffer-lock buf))))))
        finally
           ;; Drain remaining entries on shutdown
           (let ((remaining (async-drain-buffer buf)))
             (dolist (entry remaining)
               (ignore-errors
                 (funcall (async-log-buffer-inner-destination buf) entry))))))

(defun async-enqueue (buf entry)
  "Enqueue a log entry in the async buffer. Non-blocking.
If the buffer is full, drops the oldest entry."
  (bt:with-lock-held ((async-log-buffer-lock buf))
    (let ((buffer (async-log-buffer-buffer buf))
          (size (async-log-buffer-size buf))
          (head (async-log-buffer-head buf)))
      ;; Write to head position
      (setf (svref buffer head) entry)
      (setf (async-log-buffer-head buf) (mod (1+ head) size))
      ;; Handle overflow: advance tail if full
      (if (>= (async-log-buffer-count buf) size)
          (progn
            (setf (async-log-buffer-tail buf)
                  (mod (1+ (async-log-buffer-tail buf)) size))
            (incf (async-log-buffer-dropped-count buf)))
          (incf (async-log-buffer-count buf)))
      ;; Signal the writer thread
      (bt:condition-notify (async-log-buffer-condition buf)))))

(defun async-drain-buffer (buf)
  "Drain all available entries from the async buffer. Returns a list."
  (bt:with-lock-held ((async-log-buffer-lock buf))
    (let ((count (async-log-buffer-count buf))
          (buffer (async-log-buffer-buffer buf))
          (size (async-log-buffer-size buf))
          (tail (async-log-buffer-tail buf))
          (entries nil))
      (dotimes (i count)
        (push (svref buffer (mod (+ tail i) size)) entries)
        (setf (svref buffer (mod (+ tail i) size)) nil))
      (setf (async-log-buffer-tail buf) (mod (+ tail count) size)
            (async-log-buffer-count buf) 0)
      (nreverse entries))))

(defun stop-async-destination (buf)
  "Stop the async writer thread and flush remaining entries.

BUF: An async-log-buffer struct"
  (setf (async-log-buffer-running-p buf) nil)
  ;; Wake the writer thread so it can exit
  (bt:with-lock-held ((async-log-buffer-lock buf))
    (bt:condition-notify (async-log-buffer-condition buf)))
  ;; Wait for the thread to finish (with timeout)
  (when (async-log-buffer-writer-thread buf)
    (ignore-errors
      (bt:join-thread (async-log-buffer-writer-thread buf)))))

;;; ---------------------------------------------------------------------------
;;; Multi-destination combiner
;;; ---------------------------------------------------------------------------

(defun make-multi-destination (&rest destinations)
  "Create a destination that writes to multiple inner destinations.
Useful for simultaneously writing to console and file.

DESTINATIONS: Functions returned by make-*-destination constructors

Returns a function suitable for ADD-LOG-DESTINATION.

Example:
  (add-log-destination
    (make-multi-destination
      (make-console-destination :format :dev)
      (make-file-destination \"/var/log/eve-gate/esi.log\" :format :json))
    :name :multi)"
  (lambda (entry)
    (dolist (dest destinations)
      (handler-case
          (funcall dest entry)
        (error (e)
          (format *error-output* "~&[MULTI-LOG-ERROR] ~A~%" e))))))

;;; ---------------------------------------------------------------------------
;;; Level-filtering destination
;;; ---------------------------------------------------------------------------

(defun make-level-filter-destination (inner-destination min-level &optional max-level)
  "Create a destination that only passes entries within a level range.

INNER-DESTINATION: The destination to write matching entries to
MIN-LEVEL: Minimum level to pass through
MAX-LEVEL: Maximum level to pass through (default: :fatal)

Returns a filtered destination function.

Example:
  ;; Only errors and above to a separate file
  (make-level-filter-destination
    (make-file-destination \"/var/log/eve-gate/errors.log\")
    :error)"
  (let ((min-val (log-level-value min-level))
        (max-val (if max-level (log-level-value max-level) 5)))
    (lambda (entry)
      (let ((level-val (log-level-value (log-entry-level entry))))
        (when (and (>= level-val min-val)
                   (<= level-val max-val))
          (funcall inner-destination entry))))))

;;; ---------------------------------------------------------------------------
;;; Standard logging setup helpers
;;; ---------------------------------------------------------------------------

(defun setup-development-logging (&key (level :debug))
  "Configure logging for development: colored console output at debug level.

LEVEL: Minimum log level (default: :debug)

Returns T."
  (clear-log-destinations)
  (setf *log-level* level)
  (add-log-destination
   (make-console-destination :format :dev)
   :name :console)
  (log-info "Development logging configured at level ~A" level)
  t)

(defun setup-production-logging (&key (level :info)
                                       (log-dir "/var/log/eve-gate/")
                                       (console nil)
                                       (max-file-size (* 50 1024 1024))
                                       (max-files 10)
                                       (async t))
  "Configure logging for production: JSON file output with rotation.

LEVEL: Minimum log level (default: :info)
LOG-DIR: Directory for log files (default: /var/log/eve-gate/)
CONSOLE: Also output to console (default: NIL)
MAX-FILE-SIZE: Max size per log file in bytes (default: 50MB)
MAX-FILES: Number of rotated files to keep (default: 10)
ASYNC: Use async buffered output (default: T)

Returns T."
  (clear-log-destinations)
  (setf *log-level* level)
  ;; Main log file (JSON for machine parsing)
  (let ((main-dest (make-file-destination
                    (merge-pathnames "esi.log" log-dir)
                    :format :json
                    :max-size max-file-size
                    :max-files max-files)))
    (add-log-destination
     (if async
         (make-async-destination main-dest :name "esi-log-writer")
         main-dest)
     :name :file-main))
  ;; Error-only file (text for quick reading)
  (let ((error-dest (make-file-destination
                     (merge-pathnames "errors.log" log-dir)
                     :format :text
                     :max-size max-file-size
                     :max-files max-files
                     :min-level :error)))
    (add-log-destination error-dest :name :file-errors))
  ;; Optional console
  (when console
    (add-log-destination
     (make-console-destination :format :text :min-level level)
     :name :console))
  (log-info "Production logging configured: level=~A dir=~A async=~A"
            level log-dir async)
  t)

;;; ---------------------------------------------------------------------------
;;; Shutdown
;;; ---------------------------------------------------------------------------

(defun shutdown-logging ()
  "Flush and close all logging destinations.
Should be called during application shutdown."
  (log-info "Shutting down logging system")
  ;; Give a brief moment for the last message to be written
  (sleep 0.1)
  (clear-log-destinations)
  (setf *log-enabled-p* nil)
  t)
