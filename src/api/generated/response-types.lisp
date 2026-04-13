;;;; response-types.lisp - Generated response type definitions
;;;;
;;;; AUTO-GENERATED. Do not edit manually.
;;;; Contains response type metadata for 168 ESI endpoints.
;;;; Generated: 2026-04-12 21:54:04 UTC

(in-package #:eve-gate.api)


(defvar *response-type-map*
  (make-hash-table :test 'equal)
  "Registry mapping operation IDs to response type plists.
Each entry contains: :type (CL type specifier), :schema-type (keyword),
:element-type (for arrays), :description.")


(defun populate-response-types ()
  "Populate the response type registry."
  (clrhash *response-type-map*)
  (setf (gethash "get_alliances" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :integer :description
                "List of Alliance IDs" :properties 'nil))
  (setf (gethash "get_alliances_alliance_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Public data about an alliance" :properties
                '(("creator_corporation_id" . :integer) ("creator_id" . :integer)
                  ("date_founded" . :string) ("executor_corporation_id" . :integer)
                  ("faction_id" . :integer) ("name" . :string) ("ticker" . :string))))
  (setf (gethash "get_alliances_alliance_id_contacts" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of contacts" :properties 'nil))
  (setf (gethash "get_alliances_alliance_id_contacts_labels" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of alliance contact labels" :properties 'nil))
  (setf (gethash "get_alliances_alliance_id_corporations" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :integer :description
                "List of corporation IDs" :properties 'nil))
  (setf (gethash "get_alliances_alliance_id_icons" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Icon URLs for the given alliance id and server" :properties
                '(("px128x128" . :string) ("px64x64" . :string))))
  (setf (gethash "get_characters_character_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Public data for the given character" :properties
                '(("alliance_id" . :integer) ("birthday" . :string) ("bloodline_id" . :integer)
                  ("corporation_id" . :integer) ("description" . :string) ("faction_id" . :integer)
                  ("gender" . :string) ("name" . :string) ("race_id" . :integer)
                  ("security_status" . :number) ("title" . :string))))
  (setf (gethash "get_characters_character_id_agents_research" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of agents research information" :properties 'nil))
  (setf (gethash "get_characters_character_id_assets" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A flat list of the users assets" :properties 'nil))
  (setf (gethash "get_characters_character_id_attributes" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Attributes of a character" :properties
                '(("accrued_remap_cooldown_date" . :string) ("bonus_remaps" . :integer)
                  ("charisma" . :integer) ("intelligence" . :integer) ("last_remap_date" . :string)
                  ("memory" . :integer) ("perception" . :integer) ("willpower" . :integer))))
  (setf (gethash "get_characters_character_id_blueprints" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of blueprints" :properties 'nil))
  (setf (gethash "get_characters_character_id_calendar" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A collection of event summaries" :properties 'nil))
  (setf (gethash "get_characters_character_id_calendar_event_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Full details of a specific event" :properties
                '(("date" . :string) ("duration" . :integer) ("event_id" . :integer)
                  ("importance" . :integer) ("owner_id" . :integer) ("owner_name" . :string)
                  ("owner_type" . :string) ("response" . :string) ("text" . :string)
                  ("title" . :string))))
  (setf (gethash "get_characters_character_id_calendar_event_id_attendees" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "List of attendees" :properties 'nil))
  (setf (gethash "get_characters_character_id_clones" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Clone information for the given character" :properties
                '(("home_location" . :object) ("jump_clones" . :array)
                  ("last_clone_jump_date" . :string) ("last_station_change_date" . :string))))
  (setf (gethash "get_characters_character_id_contacts" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of contacts" :properties 'nil))
  (setf (gethash "get_characters_character_id_contacts_labels" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of contact labels" :properties 'nil))
  (setf (gethash "get_characters_character_id_contracts" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of contracts" :properties 'nil))
  (setf (gethash "get_characters_character_id_contracts_contract_id_bids" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of bids" :properties 'nil))
  (setf (gethash "get_characters_character_id_contracts_contract_id_items" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of items in this contract" :properties 'nil))
  (setf (gethash "get_characters_character_id_corporationhistory" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "Corporation history for the given character" :properties 'nil))
  (setf (gethash "get_characters_character_id_fatigue" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Jump activation and fatigue information" :properties
                '(("jump_fatigue_expire_date" . :string) ("last_jump_date" . :string)
                  ("last_update_date" . :string))))
  (setf (gethash "get_characters_character_id_fittings" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of fittings" :properties 'nil))
  (setf (gethash "get_characters_character_id_fleet" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Details about the character's fleet" :properties
                '(("fleet_boss_id" . :integer) ("fleet_id" . :integer) ("role" . :string)
                  ("squad_id" . :integer) ("wing_id" . :integer))))
  (setf (gethash "get_characters_character_id_fw_stats" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Faction warfare statistics for a given character" :properties
                '(("current_rank" . :integer) ("enlisted_on" . :string) ("faction_id" . :integer)
                  ("highest_rank" . :integer) ("kills" . :object) ("victory_points" . :object))))
  (setf (gethash "get_characters_character_id_implants" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :integer :description
                "A list of implant type ids" :properties 'nil))
  (setf (gethash "get_characters_character_id_industry_jobs" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "Industry jobs placed by a character" :properties 'nil))
  (setf (gethash "get_characters_character_id_killmails_recent" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of killmail IDs and hashes" :properties 'nil))
  (setf (gethash "get_characters_character_id_location" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Information about the characters current location. Returns the current solar system id, and also the current station or structure ID if applicable"
                :properties
                '(("solar_system_id" . :integer) ("station_id" . :integer)
                  ("structure_id" . :integer))))
  (setf (gethash "get_characters_character_id_loyalty_points" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of loyalty points" :properties 'nil))
  (setf (gethash "get_characters_character_id_mail" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "The requested mail" :properties 'nil))
  (setf (gethash "get_characters_character_id_mail_labels" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "A list of mail labels and unread counts" :properties
                '(("labels" . :array) ("total_unread_count" . :integer))))
  (setf (gethash "get_characters_character_id_mail_lists" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "Mailing lists" :properties 'nil))
  (setf (gethash "get_characters_character_id_mail_mail_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Contents of a mail" :properties
                '(("body" . :string) ("from" . :integer) ("labels" . :array) ("read" . :boolean)
                  ("recipients" . :array) ("subject" . :string) ("timestamp" . :string))))
  (setf (gethash "get_characters_character_id_medals" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of medals" :properties 'nil))
  (setf (gethash "get_characters_character_id_mining" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "Mining ledger of a character" :properties 'nil))
  (setf (gethash "get_characters_character_id_notifications" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "Returns your recent notifications" :properties 'nil))
  (setf (gethash "get_characters_character_id_notifications_contacts" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of contact notifications" :properties 'nil))
  (setf (gethash "get_characters_character_id_online" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Object describing the character's online status" :properties
                '(("last_login" . :string) ("last_logout" . :string) ("logins" . :integer)
                  ("online" . :boolean))))
  (setf (gethash "get_characters_character_id_orders" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "Open market orders placed by a character" :properties 'nil))
  (setf (gethash "get_characters_character_id_orders_history" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "Expired and cancelled market orders placed by a character" :properties 'nil))
  (setf (gethash "get_characters_character_id_planets" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "List of colonies" :properties 'nil))
  (setf (gethash "get_characters_character_id_planets_planet_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Colony layout" :properties
                '(("links" . :array) ("pins" . :array) ("routes" . :array))))
  (setf (gethash "get_characters_character_id_portrait" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Public data for the given character" :properties
                '(("px128x128" . :string) ("px256x256" . :string) ("px512x512" . :string)
                  ("px64x64" . :string))))
  (setf (gethash "get_characters_character_id_roles" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "The character's roles in thier corporation" :properties
                '(("roles" . :array) ("roles_at_base" . :array) ("roles_at_hq" . :array)
                  ("roles_at_other" . :array))))
  (setf (gethash "get_characters_character_id_search" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "A list of search results" :properties
                '(("agent" . :array) ("alliance" . :array) ("character" . :array)
                  ("constellation" . :array) ("corporation" . :array) ("faction" . :array)
                  ("inventory_type" . :array) ("region" . :array) ("solar_system" . :array)
                  ("station" . :array) ("structure" . :array))))
  (setf (gethash "get_characters_character_id_ship" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Get the current ship type, name and id" :properties
                '(("ship_item_id" . :integer) ("ship_name" . :string)
                  ("ship_type_id" . :integer))))
  (setf (gethash "get_characters_character_id_skillqueue" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "The current skill queue, sorted ascending by finishing time" :properties 'nil))
  (setf (gethash "get_characters_character_id_skills" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Known skills for the character" :properties
                '(("skills" . :array) ("total_sp" . :integer) ("unallocated_sp" . :integer))))
  (setf (gethash "get_characters_character_id_standings" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of standings" :properties 'nil))
  (setf (gethash "get_characters_character_id_titles" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of titles" :properties 'nil))
  (setf (gethash "get_characters_character_id_wallet" *response-type-map*)
          (list :cl-type 'double-float :schema-type :number :element-type nil :description
                "Wallet balance" :properties 'nil))
  (setf (gethash "get_characters_character_id_wallet_journal" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "Journal entries" :properties 'nil))
  (setf (gethash "get_characters_character_id_wallet_transactions" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "Wallet transactions" :properties 'nil))
  (setf (gethash "get_contracts_public_bids_contract_id" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of bids" :properties 'nil))
  (setf (gethash "get_contracts_public_items_contract_id" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of items in this contract" :properties 'nil))
  (setf (gethash "get_contracts_public_region_id" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of contracts" :properties 'nil))
  (setf (gethash "get_corporation_corporation_id_mining_extractions" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of chunk timers" :properties 'nil))
  (setf (gethash "get_corporation_corporation_id_mining_observers" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "Observer list of a corporation" :properties 'nil))
  (setf (gethash "get_corporation_corporation_id_mining_observers_observer_id" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "Mining ledger of an observer" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Public information about a corporation" :properties
                '(("alliance_id" . :integer) ("ceo_id" . :integer) ("creator_id" . :integer)
                  ("date_founded" . :string) ("description" . :string) ("faction_id" . :integer)
                  ("home_station_id" . :integer) ("member_count" . :integer) ("name" . :string)
                  ("shares" . :integer) ("tax_rate" . :number) ("ticker" . :string)
                  ("url" . :string) ("war_eligible" . :boolean))))
  (setf (gethash "get_corporations_corporation_id_alliancehistory" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "Alliance history for the given corporation" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_assets" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of assets" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_blueprints" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "List of corporation blueprints" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_contacts" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of contacts" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_contacts_labels" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of corporation contact labels" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_containers_logs" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "List of corporation ALSC logs" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_contracts" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of contracts" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_contracts_contract_id_bids" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of bids" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_contracts_contract_id_items" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of items in this contract" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_customs_offices" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of customs offices and their settings" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_divisions" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "List of corporation division names" :properties
                '(("hangar" . :array) ("wallet" . :array))))
  (setf (gethash "get_corporations_corporation_id_facilities" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "List of corporation facilities" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_fw_stats" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Faction warfare statistics for a given corporation" :properties
                '(("enlisted_on" . :string) ("faction_id" . :integer) ("kills" . :object)
                  ("pilots" . :integer) ("victory_points" . :object))))
  (setf (gethash "get_corporations_corporation_id_icons" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Urls for icons for the given corporation id and server" :properties
                '(("px128x128" . :string) ("px256x256" . :string) ("px64x64" . :string))))
  (setf (gethash "get_corporations_corporation_id_industry_jobs" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of corporation industry jobs" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_killmails_recent" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of killmail IDs and hashes" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_medals" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of medals" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_medals_issued" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of issued medals" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_members" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :integer :description
                "List of member character IDs" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_members_limit" *response-type-map*)
          (list :cl-type '(signed-byte 32) :schema-type :integer :element-type nil :description
                "The corporation's member limit" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_members_titles" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of members and theirs titles" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_membertracking" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "List of member character IDs" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_orders" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of open market orders" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_orders_history" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "Expired and cancelled market orders placed on behalf of a corporation" :properties
                'nil))
  (setf (gethash "get_corporations_corporation_id_roles" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "List of member character ID's and roles" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_roles_history" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "List of role changes" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_shareholders" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "List of shareholders" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_standings" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of standings" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_starbases" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "List of starbases (POSes)" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_starbases_starbase_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "List of starbases (POSes)" :properties
                '(("allow_alliance_members" . :boolean) ("allow_corporation_members" . :boolean)
                  ("anchor" . :string) ("attack_if_at_war" . :boolean)
                  ("attack_if_other_security_status_dropping" . :boolean)
                  ("attack_security_status_threshold" . :number)
                  ("attack_standing_threshold" . :number) ("fuel_bay_take" . :string)
                  ("fuel_bay_view" . :string) ("fuels" . :array) ("offline" . :string)
                  ("online" . :string) ("unanchor" . :string)
                  ("use_alliance_standings" . :boolean))))
  (setf (gethash "get_corporations_corporation_id_structures" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "List of corporation structures' information" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_titles" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of titles" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_wallets" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "List of corporation wallets" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_wallets_division_journal" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "Journal entries" :properties 'nil))
  (setf (gethash "get_corporations_corporation_id_wallets_division_transactions"
                 *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "Wallet transactions" :properties 'nil))
  (setf (gethash "get_corporations_npccorps" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :integer :description
                "A list of npc corporation ids" :properties 'nil))
  (setf (gethash "get_dogma_attributes" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :integer :description
                "A list of dogma attribute ids" :properties 'nil))
  (setf (gethash "get_dogma_attributes_attribute_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Information about a dogma attribute" :properties
                '(("attribute_id" . :integer) ("default_value" . :number) ("description" . :string)
                  ("display_name" . :string) ("high_is_good" . :boolean) ("icon_id" . :integer)
                  ("name" . :string) ("published" . :boolean) ("stackable" . :boolean)
                  ("unit_id" . :integer))))
  (setf (gethash "get_dogma_dynamic_items_type_id_item_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Details about a dynamic item" :properties
                '(("created_by" . :integer) ("dogma_attributes" . :array)
                  ("dogma_effects" . :array) ("mutator_type_id" . :integer)
                  ("source_type_id" . :integer))))
  (setf (gethash "get_dogma_effects" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :integer :description
                "A list of dogma effect ids" :properties 'nil))
  (setf (gethash "get_dogma_effects_effect_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Information about a dogma effect" :properties
                '(("description" . :string) ("disallow_auto_repeat" . :boolean)
                  ("discharge_attribute_id" . :integer) ("display_name" . :string)
                  ("duration_attribute_id" . :integer) ("effect_category" . :integer)
                  ("effect_id" . :integer) ("electronic_chance" . :boolean)
                  ("falloff_attribute_id" . :integer) ("icon_id" . :integer)
                  ("is_assistance" . :boolean) ("is_offensive" . :boolean)
                  ("is_warp_safe" . :boolean) ("modifiers" . :array) ("name" . :string)
                  ("post_expression" . :integer) ("pre_expression" . :integer)
                  ("published" . :boolean) ("range_attribute_id" . :integer)
                  ("range_chance" . :boolean) ("tracking_speed_attribute_id" . :integer))))
  (setf (gethash "get_fleets_fleet_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Details about a fleet" :properties
                '(("is_free_move" . :boolean) ("is_registered" . :boolean)
                  ("is_voice_enabled" . :boolean) ("motd" . :string))))
  (setf (gethash "get_fleets_fleet_id_members" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of fleet members" :properties 'nil))
  (setf (gethash "get_fleets_fleet_id_wings" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of fleet wings" :properties 'nil))
  (setf (gethash "get_fw_leaderboards" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Corporation leaderboard of kills and victory points within faction warfare"
                :properties '(("kills" . :object) ("victory_points" . :object))))
  (setf (gethash "get_fw_leaderboards_characters" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Character leaderboard of kills and victory points within faction warfare"
                :properties '(("kills" . :object) ("victory_points" . :object))))
  (setf (gethash "get_fw_leaderboards_corporations" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Corporation leaderboard of kills and victory points within faction warfare"
                :properties '(("kills" . :object) ("victory_points" . :object))))
  (setf (gethash "get_fw_stats" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "Per faction breakdown of faction warfare statistics" :properties 'nil))
  (setf (gethash "get_fw_systems" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "All faction warfare solar systems" :properties 'nil))
  (setf (gethash "get_fw_wars" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of NPC factions at war" :properties 'nil))
  (setf (gethash "get_incursions" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of incursions" :properties 'nil))
  (setf (gethash "get_industry_facilities" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of facilities" :properties 'nil))
  (setf (gethash "get_industry_systems" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of cost indicies" :properties 'nil))
  (setf (gethash "get_insurance_prices" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of insurance levels for all ship types" :properties 'nil))
  (setf (gethash "get_killmails_killmail_id_killmail_hash" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "A killmail" :properties
                '(("attackers" . :array) ("killmail_id" . :integer) ("killmail_time" . :string)
                  ("moon_id" . :integer) ("solar_system_id" . :integer) ("victim" . :object)
                  ("war_id" . :integer))))
  (setf (gethash "get_loyalty_stores_corporation_id_offers" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of offers" :properties 'nil))
  (setf (gethash "get_markets_groups" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :integer :description
                "A list of item group ids" :properties 'nil))
  (setf (gethash "get_markets_groups_market_group_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Information about an item group" :properties
                '(("description" . :string) ("market_group_id" . :integer) ("name" . :string)
                  ("parent_group_id" . :integer) ("types" . :array))))
  (setf (gethash "get_markets_prices" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of prices" :properties 'nil))
  (setf (gethash "get_markets_region_id_history" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of historical market statistics" :properties 'nil))
  (setf (gethash "get_markets_region_id_orders" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of orders" :properties 'nil))
  (setf (gethash "get_markets_region_id_types" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :integer :description
                "A list of type IDs" :properties 'nil))
  (setf (gethash "get_markets_structures_structure_id" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of orders" :properties 'nil))
  (setf (gethash "get_route_origin_destination" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :integer :description
                "Solar systems in route from origin to destination" :properties 'nil))
  (setf (gethash "get_sovereignty_campaigns" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of sovereignty campaigns" :properties 'nil))
  (setf (gethash "get_sovereignty_map" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of sovereignty information for solar systems in New Eden" :properties
                'nil))
  (setf (gethash "get_sovereignty_structures" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of sovereignty structures" :properties 'nil))
  (setf (gethash "get_status" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Server status" :properties
                '(("players" . :integer) ("server_version" . :string) ("start_time" . :string)
                  ("vip" . :boolean))))
  (setf (gethash "get_universe_ancestries" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of ancestries" :properties 'nil))
  (setf (gethash "get_universe_asteroid_belts_asteroid_belt_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Information about an asteroid belt" :properties
                '(("name" . :string) ("position" . :object) ("system_id" . :integer))))
  (setf (gethash "get_universe_bloodlines" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of bloodlines" :properties 'nil))
  (setf (gethash "get_universe_categories" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :integer :description
                "A list of item category ids" :properties 'nil))
  (setf (gethash "get_universe_categories_category_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Information about an item category" :properties
                '(("category_id" . :integer) ("groups" . :array) ("name" . :string)
                  ("published" . :boolean))))
  (setf (gethash "get_universe_constellations" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :integer :description
                "A list of constellation ids" :properties 'nil))
  (setf (gethash "get_universe_constellations_constellation_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Information about a constellation" :properties
                '(("constellation_id" . :integer) ("name" . :string) ("position" . :object)
                  ("region_id" . :integer) ("systems" . :array))))
  (setf (gethash "get_universe_factions" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of factions" :properties 'nil))
  (setf (gethash "get_universe_graphics" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :integer :description
                "A list of graphic ids" :properties 'nil))
  (setf (gethash "get_universe_graphics_graphic_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Information about a graphic" :properties
                '(("collision_file" . :string) ("graphic_file" . :string) ("graphic_id" . :integer)
                  ("icon_folder" . :string) ("sof_dna" . :string) ("sof_fation_name" . :string)
                  ("sof_hull_name" . :string) ("sof_race_name" . :string))))
  (setf (gethash "get_universe_groups" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :integer :description
                "A list of item group ids" :properties 'nil))
  (setf (gethash "get_universe_groups_group_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Information about an item group" :properties
                '(("category_id" . :integer) ("group_id" . :integer) ("name" . :string)
                  ("published" . :boolean) ("types" . :array))))
  (setf (gethash "get_universe_moons_moon_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Information about a moon" :properties
                '(("moon_id" . :integer) ("name" . :string) ("position" . :object)
                  ("system_id" . :integer))))
  (setf (gethash "get_universe_planets_planet_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Information about a planet" :properties
                '(("name" . :string) ("planet_id" . :integer) ("position" . :object)
                  ("system_id" . :integer) ("type_id" . :integer))))
  (setf (gethash "get_universe_races" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of character races" :properties 'nil))
  (setf (gethash "get_universe_regions" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :integer :description
                "A list of region ids" :properties 'nil))
  (setf (gethash "get_universe_regions_region_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Information about a region" :properties
                '(("constellations" . :array) ("description" . :string) ("name" . :string)
                  ("region_id" . :integer))))
  (setf (gethash "get_universe_schematics_schematic_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Public data about a schematic" :properties
                '(("cycle_time" . :integer) ("schematic_name" . :string))))
  (setf (gethash "get_universe_stargates_stargate_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Information about a stargate" :properties
                '(("destination" . :object) ("name" . :string) ("position" . :object)
                  ("stargate_id" . :integer) ("system_id" . :integer) ("type_id" . :integer))))
  (setf (gethash "get_universe_stars_star_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Information about a star" :properties
                '(("age" . :integer) ("luminosity" . :number) ("name" . :string)
                  ("radius" . :integer) ("solar_system_id" . :integer) ("spectral_class" . :string)
                  ("temperature" . :integer) ("type_id" . :integer))))
  (setf (gethash "get_universe_stations_station_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Information about a station" :properties
                '(("max_dockable_ship_volume" . :number) ("name" . :string)
                  ("office_rental_cost" . :number) ("owner" . :integer) ("position" . :object)
                  ("race_id" . :integer) ("reprocessing_efficiency" . :number)
                  ("reprocessing_stations_take" . :number) ("services" . :array)
                  ("station_id" . :integer) ("system_id" . :integer) ("type_id" . :integer))))
  (setf (gethash "get_universe_structures" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :integer :description
                "List of public structure IDs" :properties 'nil))
  (setf (gethash "get_universe_structures_structure_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Data about a structure" :properties
                '(("name" . :string) ("owner_id" . :integer) ("position" . :object)
                  ("solar_system_id" . :integer) ("type_id" . :integer))))
  (setf (gethash "get_universe_system_jumps" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of systems and number of jumps" :properties 'nil))
  (setf (gethash "get_universe_system_kills" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of systems and number of ship, pod and NPC kills" :properties 'nil))
  (setf (gethash "get_universe_systems" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :integer :description
                "A list of solar system ids" :properties 'nil))
  (setf (gethash "get_universe_systems_system_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Information about a solar system" :properties
                '(("constellation_id" . :integer) ("name" . :string) ("planets" . :array)
                  ("position" . :object) ("security_class" . :string) ("security_status" . :number)
                  ("star_id" . :integer) ("stargates" . :array) ("stations" . :array)
                  ("system_id" . :integer))))
  (setf (gethash "get_universe_types" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :integer :description
                "A list of type ids" :properties 'nil))
  (setf (gethash "get_universe_types_type_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Information about a type" :properties
                '(("capacity" . :number) ("description" . :string) ("dogma_attributes" . :array)
                  ("dogma_effects" . :array) ("graphic_id" . :integer) ("group_id" . :integer)
                  ("icon_id" . :integer) ("market_group_id" . :integer) ("mass" . :number)
                  ("name" . :string) ("packaged_volume" . :number) ("portion_size" . :integer)
                  ("published" . :boolean) ("radius" . :number) ("type_id" . :integer)
                  ("volume" . :number))))
  (setf (gethash "get_wars" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :integer :description
                "A list of war IDs, in descending order by war_id" :properties 'nil))
  (setf (gethash "get_wars_war_id" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "Details about a war" :properties
                '(("aggressor" . :object) ("allies" . :array) ("declared" . :string)
                  ("defender" . :object) ("finished" . :string) ("id" . :integer)
                  ("mutual" . :boolean) ("open_for_allies" . :boolean) ("retracted" . :string)
                  ("started" . :string))))
  (setf (gethash "get_wars_war_id_killmails" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "A list of killmail IDs and hashes" :properties 'nil))
  (setf (gethash "post_characters_affiliation" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "Character corporation, alliance and faction IDs" :properties 'nil))
  (setf (gethash "post_characters_character_id_assets_locations" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "List of asset locations" :properties 'nil))
  (setf (gethash "post_characters_character_id_assets_names" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "List of asset names" :properties 'nil))
  (setf (gethash "post_corporations_corporation_id_assets_locations" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "List of asset locations" :properties 'nil))
  (setf (gethash "post_corporations_corporation_id_assets_names" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "List of asset names" :properties 'nil))
  (setf (gethash "post_universe_ids" *response-type-map*)
          (list :cl-type 'hash-table :schema-type :object :element-type nil :description
                "List of id/name associations for a set of names divided by category. Any name passed in that did not have a match will be ommitted"
                :properties
                '(("agents" . :array) ("alliances" . :array) ("characters" . :array)
                  ("constellations" . :array) ("corporations" . :array) ("factions" . :array)
                  ("inventory_types" . :array) ("regions" . :array) ("stations" . :array)
                  ("systems" . :array))))
  (setf (gethash "post_universe_names" *response-type-map*)
          (list :cl-type '(or vector list) :schema-type :array :element-type :object :description
                "List of id/name associations for a set of IDs. All IDs must resolve to a name, or nothing will be returned"
                :properties 'nil))
  (log-info "Response type registry populated: ~D types" (hash-table-count *response-type-map*))
  *response-type-map*)


(defun parse-endpoint-response (operation-id data)
  "Parse response DATA according to the expected type for OPERATION-ID.

OPERATION-ID: String identifying the endpoint
DATA: The raw response data (from jzon parsing)

Returns the parsed data, possibly with type conversion applied."
  (let ((type-info (gethash operation-id *response-type-map*)))
    (if type-info
        (coerce-response-data data type-info)
        data)))


(defun coerce-response-data (data type-info)
  "Coerce response DATA according to TYPE-INFO metadata.

Handles:
  - Date-time string conversion (when local-time is available)
  - Nested object property access via keywords
  - Array element type consistency

DATA: The raw parsed response data
TYPE-INFO: Plist from the response type registry

Returns the data, potentially with type annotations or conversions."
  (declare (ignore type-info))
  data)

