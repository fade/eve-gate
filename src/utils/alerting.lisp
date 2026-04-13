;;;; alerting.lisp - Alerting and notification system for eve-gate
;;;;
;;;; Configurable alert thresholds, multiple notification channels,
;;;; severity levels, suppression/rate limiting, and escalation.
;;;;
;;;; Alert flow:
;;;;   1. Alert condition detected (from health checks, monitoring, anomalies)
;;;;   2. Alert created with severity and context
;;;;   3. Alert passes through suppression filters (dedup, cooldown)
;;;;   4. Alert routed to configured notification channels
;;;;   5. Alert recorded in history for acknowledgment and audit
;;;;
;;;; Severity levels: :info :warning :error :critical
;;;;
;;;; Notification channels: :log :console :webhook (extensible via registration)
;;;;
;;;; Design: The alerting system is decoupled from detection. Any subsystem
;;;; can fire an alert by calling FIRE-ALERT. The routing and delivery
;;;; logic is centralized here.

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Alert structure
;;; ---------------------------------------------------------------------------

(defstruct (alert-event (:constructor %make-alert-event))
  "A single alert event.

Slots:
  ID: Unique identifier for this alert instance
  NAME: Keyword identifying the alert type (e.g., :high-latency)
  SEVERITY: One of :info :warning :error :critical
  SOURCE: Subsystem that generated the alert
  MESSAGE: Human-readable description
  DETAILS: Plist of structured alert data
  TIMESTAMP: When the alert was fired
  ACKNOWLEDGED-P: Whether an operator has acknowledged this alert
  ACKNOWLEDGED-AT: When the alert was acknowledged
  ACKNOWLEDGED-BY: Who acknowledged (string)"
  (id 0 :type integer)
  (name :unknown :type keyword)
  (severity :info :type (member :info :warning :error :critical))
  (source nil :type (or null keyword))
  (message "" :type string)
  (details nil :type list)
  (timestamp (get-universal-time) :type integer)
  (acknowledged-p nil :type boolean)
  (acknowledged-at nil :type (or null integer))
  (acknowledged-by nil :type (or null string)))

(defvar *alert-id-counter* 0
  "Monotonic counter for alert IDs.")

(defvar *alert-id-lock* (bt:make-lock "alert-id-lock")
  "Lock for alert ID generation.")

(defun next-alert-id ()
  "Generate the next unique alert ID."
  (bt:with-lock-held (*alert-id-lock*)
    (incf *alert-id-counter*)))

;;; ---------------------------------------------------------------------------
;;; Alert severity utilities
;;; ---------------------------------------------------------------------------

(defun alert-severity-value (severity)
  "Return numeric priority for a severity level. Higher is more severe."
  (ecase severity
    (:info     0)
    (:warning  1)
    (:error    2)
    (:critical 3)))

(defun severity>= (a b)
  "Return T if severity A is at least as severe as B."
  (>= (alert-severity-value a) (alert-severity-value b)))

;;; ---------------------------------------------------------------------------
;;; Alert rules (threshold definitions)
;;; ---------------------------------------------------------------------------

(defstruct (alert-rule (:constructor make-alert-rule))
  "A rule defining when to fire an alert.

Slots:
  NAME: Keyword identifier for this rule
  DESCRIPTION: Human-readable description
  CHECK-FN: Function of zero args returning (values fire-p message details)
  SEVERITY: Alert severity when the rule fires
  SOURCE: Source keyword to tag alerts with
  COOLDOWN-SECONDS: Minimum seconds between firings of this rule
  ENABLED-P: Whether this rule is active"
  (name :unknown :type keyword)
  (description "" :type string)
  (check-fn (constantly nil) :type function)
  (severity :warning :type keyword)
  (source nil :type (or null keyword))
  (cooldown-seconds 300 :type (integer 0))
  (enabled-p t :type boolean))

(defvar *alert-rules* (make-hash-table :test 'eq)
  "Registry of alert rules.")

(defvar *alert-rules-lock* (bt:make-lock "alert-rules-lock")
  "Lock for alert rules registry.")

(defun register-alert-rule (rule)
  "Register an alert rule.

RULE: An ALERT-RULE struct

Returns the rule name."
  (bt:with-lock-held (*alert-rules-lock*)
    (setf (gethash (alert-rule-name rule) *alert-rules*) rule))
  (alert-rule-name rule))

(defun unregister-alert-rule (name)
  "Remove an alert rule by name."
  (bt:with-lock-held (*alert-rules-lock*)
    (remhash name *alert-rules*))
  name)

(defun list-alert-rules ()
  "Return a list of all registered alert rule names."
  (let ((names '()))
    (bt:with-lock-held (*alert-rules-lock*)
      (maphash (lambda (k v) (declare (ignore v)) (push k names))
               *alert-rules*))
    (sort names #'string< :key #'symbol-name)))

(defun get-alert-rule (name)
  "Retrieve an alert rule by name."
  (bt:with-lock-held (*alert-rules-lock*)
    (gethash name *alert-rules*)))

;;; ---------------------------------------------------------------------------
;;; Notification channels
;;; ---------------------------------------------------------------------------

(defstruct (notification-channel (:constructor make-notification-channel))
  "A notification delivery channel.

Slots:
  NAME: Keyword identifier for this channel
  DESCRIPTION: Human-readable description
  DELIVER-FN: Function (alert-event) that delivers the notification
  MIN-SEVERITY: Minimum severity to route to this channel
  ENABLED-P: Whether this channel is active"
  (name :unknown :type keyword)
  (description "" :type string)
  (deliver-fn (constantly nil) :type function)
  (min-severity :info :type keyword)
  (enabled-p t :type boolean))

(defvar *notification-channels* (make-hash-table :test 'eq)
  "Registry of notification channels.")

(defvar *channels-lock* (bt:make-lock "notification-channels-lock")
  "Lock for notification channel registry.")

(defun register-notification-channel (channel)
  "Register a notification channel.

CHANNEL: A NOTIFICATION-CHANNEL struct

Returns the channel name."
  (bt:with-lock-held (*channels-lock*)
    (setf (gethash (notification-channel-name channel) *notification-channels*) channel))
  (notification-channel-name channel))

(defun unregister-notification-channel (name)
  "Remove a notification channel."
  (bt:with-lock-held (*channels-lock*)
    (remhash name *notification-channels*)))

(defun list-notification-channels ()
  "Return a list of registered notification channel names."
  (let ((names '()))
    (bt:with-lock-held (*channels-lock*)
      (maphash (lambda (k v) (declare (ignore v)) (push k names))
               *notification-channels*))
    names))

;;; ---------------------------------------------------------------------------
;;; Built-in notification channels
;;; ---------------------------------------------------------------------------

(defun make-log-notification-channel (&key (min-severity :info))
  "Create a notification channel that logs alerts via the structured logging system.

MIN-SEVERITY: Minimum severity to log (default: :info)"
  (make-notification-channel
   :name :log
   :description "Logs alerts via structured logging"
   :min-severity min-severity
   :deliver-fn
   (lambda (alert)
     (let ((level (ecase (alert-event-severity alert)
                    (:info :info)
                    (:warning :warn)
                    (:error :error)
                    (:critical :fatal))))
       (log-event level
                  (format nil "ALERT [~A] ~A: ~A"
                          (alert-event-severity alert)
                          (alert-event-name alert)
                          (alert-event-message alert))
                  :source (or (alert-event-source alert) :alerting)
                  :alert-id (alert-event-id alert)
                  :alert-severity (alert-event-severity alert)
                  :alert-name (alert-event-name alert))))))

(defun make-console-notification-channel (&key (min-severity :warning)
                                                (stream *error-output*))
  "Create a notification channel that prints alerts to a stream.

MIN-SEVERITY: Minimum severity to print (default: :warning)
STREAM: Output stream (default: *error-output*)"
  (make-notification-channel
   :name :console
   :description "Prints alerts to console"
   :min-severity min-severity
   :deliver-fn
   (lambda (alert)
     (format stream "~&[ALERT ~A] ~A: ~A~%"
             (string-upcase (symbol-name (alert-event-severity alert)))
             (alert-event-name alert)
             (alert-event-message alert)))))

(defun make-webhook-notification-channel (url &key (min-severity :error)
                                                    (timeout 10))
  "Create a notification channel that posts alerts to a webhook URL.

URL: The webhook endpoint URL
MIN-SEVERITY: Minimum severity to post (default: :error)
TIMEOUT: HTTP timeout in seconds (default: 10)"
  (make-notification-channel
   :name :webhook
   :description (format nil "Webhook: ~A" url)
   :min-severity min-severity
   :deliver-fn
   (lambda (alert)
     (handler-case
         (let ((payload (com.inuoe.jzon:stringify
                         (alexandria:plist-hash-table
                          (list "alert_id" (alert-event-id alert)
                                "name" (symbol-name (alert-event-name alert))
                                "severity" (symbol-name (alert-event-severity alert))
                                "message" (alert-event-message alert)
                                "timestamp" (alert-event-timestamp alert)
                                "source" (when (alert-event-source alert)
                                           (symbol-name (alert-event-source alert)))
                                "details" (alert-event-details alert))
                          :test 'equal))))
           (dex:post url
                     :content payload
                     :headers '(("content-type" . "application/json"))
                     :connect-timeout timeout
                     :read-timeout timeout))
       (error (e)
         (log-error "Webhook delivery failed for alert ~D: ~A"
                    (alert-event-id alert) e))))))

(defun make-callback-notification-channel (name callback-fn &key (min-severity :info))
  "Create a notification channel that calls a custom function.

NAME: Channel identifier keyword
CALLBACK-FN: Function (alert-event) to call
MIN-SEVERITY: Minimum severity (default: :info)"
  (make-notification-channel
   :name name
   :description "Custom callback channel"
   :min-severity min-severity
   :deliver-fn callback-fn))

;;; ---------------------------------------------------------------------------
;;; Alert suppression and rate limiting
;;; ---------------------------------------------------------------------------

(defvar *alert-last-fired* (make-hash-table :test 'eq)
  "Maps alert-rule name -> universal-time of last firing.
Used for cooldown enforcement.")

(defvar *alert-suppression-lock* (bt:make-lock "alert-suppression-lock")
  "Lock for alert suppression state.")

(defun alert-suppressed-p (rule-name cooldown-seconds)
  "Check if an alert should be suppressed due to cooldown.

RULE-NAME: The alert rule keyword
COOLDOWN-SECONDS: Minimum seconds between firings

Returns T if the alert should be suppressed."
  (bt:with-lock-held (*alert-suppression-lock*)
    (let ((last-fired (gethash rule-name *alert-last-fired* 0)))
      (< (- (get-universal-time) last-fired) cooldown-seconds))))

(defun record-alert-fired (rule-name)
  "Record that an alert rule has fired."
  (bt:with-lock-held (*alert-suppression-lock*)
    (setf (gethash rule-name *alert-last-fired*) (get-universal-time))))

;;; ---------------------------------------------------------------------------
;;; Alert history
;;; ---------------------------------------------------------------------------

(defvar *alert-history* nil
  "List of recent alert events, newest first.")

(defvar *alert-history-lock* (bt:make-lock "alert-history-lock")
  "Lock for alert history.")

(defvar *alert-history-max* 500
  "Maximum alert events to retain in history.")

(defun record-alert-in-history (alert)
  "Record an alert event in the history buffer."
  (bt:with-lock-held (*alert-history-lock*)
    (push alert *alert-history*)
    (when (> (length *alert-history*) *alert-history-max*)
      (setf *alert-history* (subseq *alert-history* 0 *alert-history-max*))))
  alert)

(defun alert-history (&key (n 50) severity source since)
  "Query alert history with optional filters.

N: Maximum number of events to return (default: 50)
SEVERITY: Filter by severity keyword
SOURCE: Filter by source keyword
SINCE: Only include alerts after this universal-time

Returns a list of ALERT-EVENT structs, newest first."
  (bt:with-lock-held (*alert-history-lock*)
    (let ((filtered *alert-history*))
      (when severity
        (setf filtered (remove-if-not
                        (lambda (a) (eq (alert-event-severity a) severity))
                        filtered)))
      (when source
        (setf filtered (remove-if-not
                        (lambda (a) (eq (alert-event-source a) source))
                        filtered)))
      (when since
        (setf filtered (remove-if
                        (lambda (a) (< (alert-event-timestamp a) since))
                        filtered)))
      (subseq filtered 0 (min n (length filtered))))))

(defun unacknowledged-alerts (&optional (severity nil))
  "Return all unacknowledged alerts, optionally filtered by severity.

SEVERITY: Optional severity keyword to filter by

Returns a list of ALERT-EVENT structs."
  (bt:with-lock-held (*alert-history-lock*)
    (remove-if (lambda (a)
                 (or (alert-event-acknowledged-p a)
                     (and severity
                          (not (eq (alert-event-severity a) severity)))))
               *alert-history*)))

(defun acknowledge-alert (alert-id &key (by "operator"))
  "Acknowledge an alert by its ID.

ALERT-ID: Integer ID of the alert to acknowledge
BY: String identifying who acknowledged (default: \"operator\")

Returns the acknowledged alert, or NIL if not found."
  (bt:with-lock-held (*alert-history-lock*)
    (let ((alert (find alert-id *alert-history*
                       :key #'alert-event-id)))
      (when alert
        (setf (alert-event-acknowledged-p alert) t
              (alert-event-acknowledged-at alert) (get-universal-time)
              (alert-event-acknowledged-by alert) by)
        (log-info "Alert ~D (~A) acknowledged by ~A"
                  alert-id (alert-event-name alert) by)
        alert))))

(defun acknowledge-all-alerts (&key (by "operator") severity)
  "Acknowledge all unacknowledged alerts.

BY: Who is acknowledging (default: \"operator\")
SEVERITY: Optional filter — only acknowledge alerts of this severity

Returns the count of acknowledged alerts."
  (let ((count 0))
    (bt:with-lock-held (*alert-history-lock*)
      (dolist (alert *alert-history*)
        (when (and (not (alert-event-acknowledged-p alert))
                   (or (null severity)
                       (eq (alert-event-severity alert) severity)))
          (setf (alert-event-acknowledged-p alert) t
                (alert-event-acknowledged-at alert) (get-universal-time)
                (alert-event-acknowledged-by alert) by)
          (incf count))))
    (when (plusp count)
      (log-info "~D alerts acknowledged by ~A" count by))
    count))

;;; ---------------------------------------------------------------------------
;;; Core alert firing
;;; ---------------------------------------------------------------------------

(defun fire-alert (name severity message &key source details)
  "Fire an alert, routing it through suppression and notification channels.

NAME: Alert type keyword (e.g., :high-latency, :auth-failure)
SEVERITY: One of :info :warning :error :critical
MESSAGE: Human-readable description
SOURCE: Subsystem keyword that generated the alert
DETAILS: Plist of additional structured data

Returns the alert-event if delivered, NIL if suppressed."
  ;; Check suppression (using rule cooldown if rule exists)
  (let ((rule (get-alert-rule name)))
    (when (and rule (alert-suppressed-p name (alert-rule-cooldown-seconds rule)))
      (log-trace "Alert ~A suppressed (cooldown)" name)
      (return-from fire-alert nil)))
  ;; Create the alert event
  (let ((alert (%make-alert-event
                :id (next-alert-id)
                :name name
                :severity severity
                :source source
                :message message
                :details (or details '()))))
    ;; Record in history
    (record-alert-in-history alert)
    ;; Record firing time for suppression
    (record-alert-fired name)
    ;; Deliver to all eligible channels
    (bt:with-lock-held (*channels-lock*)
      (maphash (lambda (ch-name channel)
                 (declare (ignore ch-name))
                 (when (and (notification-channel-enabled-p channel)
                            (severity>= severity
                                        (notification-channel-min-severity channel)))
                   (handler-case
                       (funcall (notification-channel-deliver-fn channel) alert)
                     (error (e)
                       (log-error "Alert delivery to ~A failed: ~A"
                                  (notification-channel-name channel) e)))))
               *notification-channels*))
    ;; Increment alert counter
    (increment-counter :alerts-fired)
    (increment-counter (intern (format nil "ALERTS-~A" (symbol-name severity))
                               :keyword))
    alert))

;;; ---------------------------------------------------------------------------
;;; Built-in alert rules
;;; ---------------------------------------------------------------------------

(defun make-health-degraded-alert-rule ()
  "Create an alert rule that fires when system health degrades."
  (make-alert-rule
   :name :health-degraded
   :description "Fires when overall system health is not :healthy"
   :severity :warning
   :source :health
   :cooldown-seconds 300
   :check-fn
   (lambda ()
     (let ((health (compute-system-health)))
       (unless (eq (system-health-status health) :healthy)
         (values t
                 (format nil "System health: ~A" (system-health-summary health))
                 (list :status (system-health-status health))))))))

(defun make-high-error-rate-alert-rule (&key (threshold 10) (window-seconds 60))
  "Create an alert rule for high error rates.

THRESHOLD: Error count in window that triggers alert (default: 10)
WINDOW-SECONDS: Evaluation window (default: 60s)"
  (declare (ignore window-seconds))
  (make-alert-rule
   :name :high-error-rate
   :description (format nil "Fires when >~D errors in window" threshold)
   :severity :error
   :source :error-handling
   :cooldown-seconds 120
   :check-fn
   (lambda ()
     (let ((total-errors (counter-value :errors)))
       (when (> total-errors threshold)
         (values t
                 (format nil "High error rate: ~D errors" total-errors)
                 (list :error-count total-errors :threshold threshold)))))))

(defun make-sla-violation-alert-rule ()
  "Create an alert rule for SLA violations."
  (make-alert-rule
   :name :sla-violation
   :description "Fires when any SLA target is violated"
   :severity :critical
   :source :monitoring
   :cooldown-seconds 300
   :check-fn
   (lambda ()
     (let ((violations (remove-if #'sla-status-compliant-p
                                  (evaluate-all-sla-targets))))
       (when violations
         (values t
                 (format nil "SLA violation: ~{~A~^, ~}"
                         (mapcar (lambda (s)
                                   (sla-target-name (sla-status-target s)))
                                 violations))
                 (list :violations (length violations))))))))

(defun make-anomaly-detected-alert-rule ()
  "Create an alert rule for performance anomalies."
  (make-alert-rule
   :name :anomaly-detected
   :description "Fires when performance anomalies are detected"
   :severity :warning
   :source :monitoring
   :cooldown-seconds 180
   :check-fn
   (lambda ()
     (let ((anomalies (detect-anomalies)))
       (when anomalies
         (let ((worst (reduce (lambda (a b)
                                (if (> (alert-severity-value (anomaly-severity a))
                                       (alert-severity-value (anomaly-severity b)))
                                    a b))
                              anomalies)))
           (values t
                   (format nil "~D anomalies detected, worst: ~A"
                           (length anomalies)
                           (anomaly-message worst))
                   (list :anomaly-count (length anomalies)
                         :worst-metric (anomaly-metric-name worst)))))))))

;;; ---------------------------------------------------------------------------
;;; Alert evaluation sweep
;;; ---------------------------------------------------------------------------

(defun evaluate-alert-rules ()
  "Evaluate all enabled alert rules, firing alerts for any that trigger.

Returns a list of fired ALERT-EVENT structs."
  (let ((fired '())
        (rules '()))
    (bt:with-lock-held (*alert-rules-lock*)
      (maphash (lambda (k v) (declare (ignore k)) (push v rules))
               *alert-rules*))
    (dolist (rule rules)
      (when (alert-rule-enabled-p rule)
        (handler-case
            (multiple-value-bind (fire-p message details)
                (funcall (alert-rule-check-fn rule))
              (when fire-p
                (let ((alert (fire-alert (alert-rule-name rule)
                                         (alert-rule-severity rule)
                                         (or message "Alert condition triggered")
                                         :source (alert-rule-source rule)
                                         :details details)))
                  (when alert (push alert fired)))))
          (error (e)
            (log-error "Alert rule ~A check failed: ~A"
                       (alert-rule-name rule) e)))))
    (nreverse fired)))

;;; ---------------------------------------------------------------------------
;;; Initialization
;;; ---------------------------------------------------------------------------

(defvar *alerting-initialized-p* nil
  "Whether the alerting system has been initialized.")

(defun initialize-alerting (&key (enable-log-channel t)
                                  (enable-console-channel t)
                                  (console-min-severity :warning)
                                  webhook-url
                                  (register-default-rules t))
  "Initialize the alerting system with default channels and rules.

ENABLE-LOG-CHANNEL: Register the log notification channel (default: T)
ENABLE-CONSOLE-CHANNEL: Register the console notification channel (default: T)
CONSOLE-MIN-SEVERITY: Minimum severity for console output (default: :warning)
WEBHOOK-URL: Optional webhook URL for external notification
REGISTER-DEFAULT-RULES: Register built-in alert rules (default: T)

Returns T."
  ;; Reset state
  (setf *alert-id-counter* 0)
  ;; Register channels
  (when enable-log-channel
    (register-notification-channel (make-log-notification-channel)))
  (when enable-console-channel
    (register-notification-channel
     (make-console-notification-channel :min-severity console-min-severity)))
  (when webhook-url
    (register-notification-channel
     (make-webhook-notification-channel webhook-url)))
  ;; Register default rules
  (when register-default-rules
    (register-alert-rule (make-health-degraded-alert-rule))
    (register-alert-rule (make-high-error-rate-alert-rule))
    (register-alert-rule (make-sla-violation-alert-rule))
    (register-alert-rule (make-anomaly-detected-alert-rule)))
  (setf *alerting-initialized-p* t)
  (log-info "Alerting initialized: ~D channels, ~D rules"
            (hash-table-count *notification-channels*)
            (hash-table-count *alert-rules*))
  t)

(defun ensure-alerting ()
  "Ensure the alerting system is initialized."
  (unless *alerting-initialized-p*
    (initialize-alerting)))

;;; ---------------------------------------------------------------------------
;;; REPL utilities
;;; ---------------------------------------------------------------------------

(defun alerting-status (&optional (stream *standard-output*))
  "Print alerting system status to STREAM."
  (format stream "~&=== Alerting Status ===~%")
  (format stream "  Initialized: ~A~%" *alerting-initialized-p*)
  (format stream "  Channels: ~{~A~^, ~}~%" (list-notification-channels))
  (format stream "  Rules: ~{~A~^, ~}~%" (list-alert-rules))
  (let ((unacked (unacknowledged-alerts)))
    (format stream "  Unacknowledged: ~D alerts~%" (length unacked))
    (when unacked
      (dolist (a (subseq unacked 0 (min 5 (length unacked))))
        (format stream "    [~A] ~A: ~A~%"
                (string-upcase (symbol-name (alert-event-severity a)))
                (alert-event-name a)
                (alert-event-message a)))))
  (format stream "  Total fired: ~D~%" (counter-value :alerts-fired))
  (format stream "=== End Alerting Status ===~%")
  (values))
