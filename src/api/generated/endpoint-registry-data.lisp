;;;; endpoint-registry-data.lisp - Generated endpoint registry
;;;;
;;;; AUTO-GENERATED. Do not edit manually.
;;;; Contains runtime metadata for 195 ESI endpoints.
;;;; Generated: 2026-04-12 21:54:04 UTC

(in-package #:eve-gate.api)


(defvar *endpoint-registry*
  (make-hash-table :test 'equal)
  "Registry mapping operation IDs to endpoint metadata plists.
Each entry contains: :path, :method, :category, :requires-auth, :scopes,
:paginated, :cache-duration, :function-name, :deprecated.")


(defun populate-endpoint-registry ()
  "Populate the endpoint registry with all ESI endpoint metadata."
  (clrhash *endpoint-registry*)
  (setf (gethash "delete_characters_character_id_contacts" *endpoint-registry*)
          (list :path "/characters/{character_id}/contacts/" :method :delete :category "characters"
                :function-name "delete-characters-character-id-contacts" :requires-auth t :scopes
                '("esi-characters.write_contacts.v1") :paginated nil :cache-duration nil
                :deprecated nil))
  (setf (gethash "delete_characters_character_id_fittings_fitting_id" *endpoint-registry*)
          (list :path "/characters/{character_id}/fittings/{fitting_id}/" :method :delete :category
                "characters" :function-name "delete-characters-character-id-fittings-fitting-id"
                :requires-auth t :scopes '("esi-fittings.write_fittings.v1") :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "delete_characters_character_id_mail_labels_label_id" *endpoint-registry*)
          (list :path "/characters/{character_id}/mail/labels/{label_id}/" :method :delete
                :category "characters" :function-name
                "delete-characters-character-id-mail-labels-label-id" :requires-auth t :scopes
                '("esi-mail.organize_mail.v1") :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "delete_characters_character_id_mail_mail_id" *endpoint-registry*)
          (list :path "/characters/{character_id}/mail/{mail_id}/" :method :delete :category
                "characters" :function-name "delete-characters-character-id-mail-mail-id"
                :requires-auth t :scopes '("esi-mail.organize_mail.v1") :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "delete_fleets_fleet_id_members_member_id" *endpoint-registry*)
          (list :path "/fleets/{fleet_id}/members/{member_id}/" :method :delete :category "fleets"
                :function-name "delete-fleets-fleet-id-members-member-id" :requires-auth t :scopes
                '("esi-fleets.write_fleet.v1") :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "delete_fleets_fleet_id_squads_squad_id" *endpoint-registry*)
          (list :path "/fleets/{fleet_id}/squads/{squad_id}/" :method :delete :category "fleets"
                :function-name "delete-fleets-fleet-id-squads-squad-id" :requires-auth t :scopes
                '("esi-fleets.write_fleet.v1") :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "delete_fleets_fleet_id_wings_wing_id" *endpoint-registry*)
          (list :path "/fleets/{fleet_id}/wings/{wing_id}/" :method :delete :category "fleets"
                :function-name "delete-fleets-fleet-id-wings-wing-id" :requires-auth t :scopes
                '("esi-fleets.write_fleet.v1") :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "get_alliances" *endpoint-registry*)
          (list :path "/alliances/" :method :get :category "alliances" :function-name
                "get-alliances" :requires-auth nil :scopes 'nil :paginated nil :cache-duration 3600
                :deprecated nil))
  (setf (gethash "get_alliances_alliance_id" *endpoint-registry*)
          (list :path "/alliances/{alliance_id}/" :method :get :category "alliances" :function-name
                "get-alliances-alliance-id" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_alliances_alliance_id_contacts" *endpoint-registry*)
          (list :path "/alliances/{alliance_id}/contacts/" :method :get :category "alliances"
                :function-name "get-alliances-alliance-id-contacts" :requires-auth t :scopes
                '("esi-alliances.read_contacts.v1") :paginated t :cache-duration 300 :deprecated
                nil))
  (setf (gethash "get_alliances_alliance_id_contacts_labels" *endpoint-registry*)
          (list :path "/alliances/{alliance_id}/contacts/labels/" :method :get :category
                "alliances" :function-name "get-alliances-alliance-id-contacts-labels"
                :requires-auth t :scopes '("esi-alliances.read_contacts.v1") :paginated nil
                :cache-duration 300 :deprecated nil))
  (setf (gethash "get_alliances_alliance_id_corporations" *endpoint-registry*)
          (list :path "/alliances/{alliance_id}/corporations/" :method :get :category "alliances"
                :function-name "get-alliances-alliance-id-corporations" :requires-auth nil :scopes
                'nil :paginated nil :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_alliances_alliance_id_icons" *endpoint-registry*)
          (list :path "/alliances/{alliance_id}/icons/" :method :get :category "alliances"
                :function-name "get-alliances-alliance-id-icons" :requires-auth nil :scopes 'nil
                :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "get_characters_character_id" *endpoint-registry*)
          (list :path "/characters/{character_id}/" :method :get :category "characters"
                :function-name "get-characters-character-id" :requires-auth nil :scopes 'nil
                :paginated nil :cache-duration 604800 :deprecated nil))
  (setf (gethash "get_characters_character_id_agents_research" *endpoint-registry*)
          (list :path "/characters/{character_id}/agents_research/" :method :get :category
                "characters" :function-name "get-characters-character-id-agents-research"
                :requires-auth t :scopes '("esi-characters.read_agents_research.v1") :paginated nil
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_characters_character_id_assets" *endpoint-registry*)
          (list :path "/characters/{character_id}/assets/" :method :get :category "characters"
                :function-name "get-characters-character-id-assets" :requires-auth t :scopes
                '("esi-assets.read_assets.v1") :paginated t :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_characters_character_id_attributes" *endpoint-registry*)
          (list :path "/characters/{character_id}/attributes/" :method :get :category "characters"
                :function-name "get-characters-character-id-attributes" :requires-auth t :scopes
                '("esi-skills.read_skills.v1") :paginated nil :cache-duration 120 :deprecated nil))
  (setf (gethash "get_characters_character_id_blueprints" *endpoint-registry*)
          (list :path "/characters/{character_id}/blueprints/" :method :get :category "characters"
                :function-name "get-characters-character-id-blueprints" :requires-auth t :scopes
                '("esi-characters.read_blueprints.v1") :paginated t :cache-duration 3600
                :deprecated nil))
  (setf (gethash "get_characters_character_id_calendar" *endpoint-registry*)
          (list :path "/characters/{character_id}/calendar/" :method :get :category "characters"
                :function-name "get-characters-character-id-calendar" :requires-auth t :scopes
                '("esi-calendar.read_calendar_events.v1") :paginated nil :cache-duration 5
                :deprecated nil))
  (setf (gethash "get_characters_character_id_calendar_event_id" *endpoint-registry*)
          (list :path "/characters/{character_id}/calendar/{event_id}/" :method :get :category
                "characters" :function-name "get-characters-character-id-calendar-event-id"
                :requires-auth t :scopes '("esi-calendar.read_calendar_events.v1") :paginated nil
                :cache-duration 5 :deprecated nil))
  (setf (gethash "get_characters_character_id_calendar_event_id_attendees" *endpoint-registry*)
          (list :path "/characters/{character_id}/calendar/{event_id}/attendees/" :method :get
                :category "characters" :function-name
                "get-characters-character-id-calendar-event-id-attendees" :requires-auth t :scopes
                '("esi-calendar.read_calendar_events.v1") :paginated nil :cache-duration 600
                :deprecated nil))
  (setf (gethash "get_characters_character_id_clones" *endpoint-registry*)
          (list :path "/characters/{character_id}/clones/" :method :get :category "characters"
                :function-name "get-characters-character-id-clones" :requires-auth t :scopes
                '("esi-clones.read_clones.v1") :paginated nil :cache-duration 120 :deprecated nil))
  (setf (gethash "get_characters_character_id_contacts" *endpoint-registry*)
          (list :path "/characters/{character_id}/contacts/" :method :get :category "characters"
                :function-name "get-characters-character-id-contacts" :requires-auth t :scopes
                '("esi-characters.read_contacts.v1") :paginated t :cache-duration 300 :deprecated
                nil))
  (setf (gethash "get_characters_character_id_contacts_labels" *endpoint-registry*)
          (list :path "/characters/{character_id}/contacts/labels/" :method :get :category
                "characters" :function-name "get-characters-character-id-contacts-labels"
                :requires-auth t :scopes '("esi-characters.read_contacts.v1") :paginated nil
                :cache-duration 300 :deprecated nil))
  (setf (gethash "get_characters_character_id_contracts" *endpoint-registry*)
          (list :path "/characters/{character_id}/contracts/" :method :get :category "characters"
                :function-name "get-characters-character-id-contracts" :requires-auth t :scopes
                '("esi-contracts.read_character_contracts.v1") :paginated t :cache-duration 300
                :deprecated nil))
  (setf (gethash "get_characters_character_id_contracts_contract_id_bids" *endpoint-registry*)
          (list :path "/characters/{character_id}/contracts/{contract_id}/bids/" :method :get
                :category "characters" :function-name
                "get-characters-character-id-contracts-contract-id-bids" :requires-auth t :scopes
                '("esi-contracts.read_character_contracts.v1") :paginated nil :cache-duration 300
                :deprecated nil))
  (setf (gethash "get_characters_character_id_contracts_contract_id_items" *endpoint-registry*)
          (list :path "/characters/{character_id}/contracts/{contract_id}/items/" :method :get
                :category "characters" :function-name
                "get-characters-character-id-contracts-contract-id-items" :requires-auth t :scopes
                '("esi-contracts.read_character_contracts.v1") :paginated nil :cache-duration 3600
                :deprecated nil))
  (setf (gethash "get_characters_character_id_corporationhistory" *endpoint-registry*)
          (list :path "/characters/{character_id}/corporationhistory/" :method :get :category
                "characters" :function-name "get-characters-character-id-corporationhistory"
                :requires-auth nil :scopes 'nil :paginated nil :cache-duration 86400 :deprecated
                nil))
  (setf (gethash "get_characters_character_id_fatigue" *endpoint-registry*)
          (list :path "/characters/{character_id}/fatigue/" :method :get :category "characters"
                :function-name "get-characters-character-id-fatigue" :requires-auth t :scopes
                '("esi-characters.read_fatigue.v1") :paginated nil :cache-duration 300 :deprecated
                nil))
  (setf (gethash "get_characters_character_id_fittings" *endpoint-registry*)
          (list :path "/characters/{character_id}/fittings/" :method :get :category "characters"
                :function-name "get-characters-character-id-fittings" :requires-auth t :scopes
                '("esi-fittings.read_fittings.v1") :paginated nil :cache-duration 300 :deprecated
                nil))
  (setf (gethash "get_characters_character_id_fleet" *endpoint-registry*)
          (list :path "/characters/{character_id}/fleet/" :method :get :category "characters"
                :function-name "get-characters-character-id-fleet" :requires-auth t :scopes
                '("esi-fleets.read_fleet.v1") :paginated nil :cache-duration 60 :deprecated nil))
  (setf (gethash "get_characters_character_id_fw_stats" *endpoint-registry*)
          (list :path "/characters/{character_id}/fw/stats/" :method :get :category "characters"
                :function-name "get-characters-character-id-fw-stats" :requires-auth t :scopes
                '("esi-characters.read_fw_stats.v1") :paginated nil :cache-duration nil :deprecated
                nil))
  (setf (gethash "get_characters_character_id_implants" *endpoint-registry*)
          (list :path "/characters/{character_id}/implants/" :method :get :category "characters"
                :function-name "get-characters-character-id-implants" :requires-auth t :scopes
                '("esi-clones.read_implants.v1") :paginated nil :cache-duration 120 :deprecated
                nil))
  (setf (gethash "get_characters_character_id_industry_jobs" *endpoint-registry*)
          (list :path "/characters/{character_id}/industry/jobs/" :method :get :category
                "characters" :function-name "get-characters-character-id-industry-jobs"
                :requires-auth t :scopes '("esi-industry.read_character_jobs.v1") :paginated nil
                :cache-duration 300 :deprecated nil))
  (setf (gethash "get_characters_character_id_killmails_recent" *endpoint-registry*)
          (list :path "/characters/{character_id}/killmails/recent/" :method :get :category
                "characters" :function-name "get-characters-character-id-killmails-recent"
                :requires-auth t :scopes '("esi-killmails.read_killmails.v1") :paginated t
                :cache-duration 300 :deprecated nil))
  (setf (gethash "get_characters_character_id_location" *endpoint-registry*)
          (list :path "/characters/{character_id}/location/" :method :get :category "characters"
                :function-name "get-characters-character-id-location" :requires-auth t :scopes
                '("esi-location.read_location.v1") :paginated nil :cache-duration 5 :deprecated
                nil))
  (setf (gethash "get_characters_character_id_loyalty_points" *endpoint-registry*)
          (list :path "/characters/{character_id}/loyalty/points/" :method :get :category
                "characters" :function-name "get-characters-character-id-loyalty-points"
                :requires-auth t :scopes '("esi-characters.read_loyalty.v1") :paginated nil
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_characters_character_id_mail" *endpoint-registry*)
          (list :path "/characters/{character_id}/mail/" :method :get :category "characters"
                :function-name "get-characters-character-id-mail" :requires-auth t :scopes
                '("esi-mail.read_mail.v1") :paginated nil :cache-duration 30 :deprecated nil))
  (setf (gethash "get_characters_character_id_mail_labels" *endpoint-registry*)
          (list :path "/characters/{character_id}/mail/labels/" :method :get :category "characters"
                :function-name "get-characters-character-id-mail-labels" :requires-auth t :scopes
                '("esi-mail.read_mail.v1") :paginated nil :cache-duration 30 :deprecated nil))
  (setf (gethash "get_characters_character_id_mail_lists" *endpoint-registry*)
          (list :path "/characters/{character_id}/mail/lists/" :method :get :category "characters"
                :function-name "get-characters-character-id-mail-lists" :requires-auth t :scopes
                '("esi-mail.read_mail.v1") :paginated nil :cache-duration 120 :deprecated nil))
  (setf (gethash "get_characters_character_id_mail_mail_id" *endpoint-registry*)
          (list :path "/characters/{character_id}/mail/{mail_id}/" :method :get :category
                "characters" :function-name "get-characters-character-id-mail-mail-id"
                :requires-auth t :scopes '("esi-mail.read_mail.v1") :paginated nil :cache-duration
                30 :deprecated nil))
  (setf (gethash "get_characters_character_id_medals" *endpoint-registry*)
          (list :path "/characters/{character_id}/medals/" :method :get :category "characters"
                :function-name "get-characters-character-id-medals" :requires-auth t :scopes
                '("esi-characters.read_medals.v1") :paginated nil :cache-duration 3600 :deprecated
                nil))
  (setf (gethash "get_characters_character_id_mining" *endpoint-registry*)
          (list :path "/characters/{character_id}/mining/" :method :get :category "characters"
                :function-name "get-characters-character-id-mining" :requires-auth t :scopes
                '("esi-industry.read_character_mining.v1") :paginated t :cache-duration 600
                :deprecated nil))
  (setf (gethash "get_characters_character_id_notifications" *endpoint-registry*)
          (list :path "/characters/{character_id}/notifications/" :method :get :category
                "characters" :function-name "get-characters-character-id-notifications"
                :requires-auth t :scopes '("esi-characters.read_notifications.v1") :paginated nil
                :cache-duration 600 :deprecated nil))
  (setf (gethash "get_characters_character_id_notifications_contacts" *endpoint-registry*)
          (list :path "/characters/{character_id}/notifications/contacts/" :method :get :category
                "characters" :function-name "get-characters-character-id-notifications-contacts"
                :requires-auth t :scopes '("esi-characters.read_notifications.v1") :paginated nil
                :cache-duration 600 :deprecated nil))
  (setf (gethash "get_characters_character_id_online" *endpoint-registry*)
          (list :path "/characters/{character_id}/online/" :method :get :category "characters"
                :function-name "get-characters-character-id-online" :requires-auth t :scopes
                '("esi-location.read_online.v1") :paginated nil :cache-duration 60 :deprecated
                nil))
  (setf (gethash "get_characters_character_id_orders" *endpoint-registry*)
          (list :path "/characters/{character_id}/orders/" :method :get :category "characters"
                :function-name "get-characters-character-id-orders" :requires-auth t :scopes
                '("esi-markets.read_character_orders.v1") :paginated nil :cache-duration 1200
                :deprecated nil))
  (setf (gethash "get_characters_character_id_orders_history" *endpoint-registry*)
          (list :path "/characters/{character_id}/orders/history/" :method :get :category
                "characters" :function-name "get-characters-character-id-orders-history"
                :requires-auth t :scopes '("esi-markets.read_character_orders.v1") :paginated t
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_characters_character_id_planets" *endpoint-registry*)
          (list :path "/characters/{character_id}/planets/" :method :get :category "characters"
                :function-name "get-characters-character-id-planets" :requires-auth t :scopes
                '("esi-planets.manage_planets.v1") :paginated nil :cache-duration 600 :deprecated
                nil))
  (setf (gethash "get_characters_character_id_planets_planet_id" *endpoint-registry*)
          (list :path "/characters/{character_id}/planets/{planet_id}/" :method :get :category
                "characters" :function-name "get-characters-character-id-planets-planet-id"
                :requires-auth t :scopes '("esi-planets.manage_planets.v1") :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "get_characters_character_id_portrait" *endpoint-registry*)
          (list :path "/characters/{character_id}/portrait/" :method :get :category "characters"
                :function-name "get-characters-character-id-portrait" :requires-auth nil :scopes
                'nil :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "get_characters_character_id_roles" *endpoint-registry*)
          (list :path "/characters/{character_id}/roles/" :method :get :category "characters"
                :function-name "get-characters-character-id-roles" :requires-auth t :scopes
                '("esi-characters.read_corporation_roles.v1") :paginated nil :cache-duration 3600
                :deprecated nil))
  (setf (gethash "get_characters_character_id_search" *endpoint-registry*)
          (list :path "/characters/{character_id}/search/" :method :get :category "characters"
                :function-name "get-characters-character-id-search" :requires-auth t :scopes
                '("esi-search.search_structures.v1") :paginated nil :cache-duration 3600
                :deprecated nil))
  (setf (gethash "get_characters_character_id_ship" *endpoint-registry*)
          (list :path "/characters/{character_id}/ship/" :method :get :category "characters"
                :function-name "get-characters-character-id-ship" :requires-auth t :scopes
                '("esi-location.read_ship_type.v1") :paginated nil :cache-duration 5 :deprecated
                nil))
  (setf (gethash "get_characters_character_id_skillqueue" *endpoint-registry*)
          (list :path "/characters/{character_id}/skillqueue/" :method :get :category "characters"
                :function-name "get-characters-character-id-skillqueue" :requires-auth t :scopes
                '("esi-skills.read_skillqueue.v1") :paginated nil :cache-duration 120 :deprecated
                nil))
  (setf (gethash "get_characters_character_id_skills" *endpoint-registry*)
          (list :path "/characters/{character_id}/skills/" :method :get :category "characters"
                :function-name "get-characters-character-id-skills" :requires-auth t :scopes
                '("esi-skills.read_skills.v1") :paginated nil :cache-duration 120 :deprecated nil))
  (setf (gethash "get_characters_character_id_standings" *endpoint-registry*)
          (list :path "/characters/{character_id}/standings/" :method :get :category "characters"
                :function-name "get-characters-character-id-standings" :requires-auth t :scopes
                '("esi-characters.read_standings.v1") :paginated nil :cache-duration 3600
                :deprecated nil))
  (setf (gethash "get_characters_character_id_titles" *endpoint-registry*)
          (list :path "/characters/{character_id}/titles/" :method :get :category "characters"
                :function-name "get-characters-character-id-titles" :requires-auth t :scopes
                '("esi-characters.read_titles.v1") :paginated nil :cache-duration 3600 :deprecated
                nil))
  (setf (gethash "get_characters_character_id_wallet" *endpoint-registry*)
          (list :path "/characters/{character_id}/wallet/" :method :get :category "characters"
                :function-name "get-characters-character-id-wallet" :requires-auth t :scopes
                '("esi-wallet.read_character_wallet.v1") :paginated nil :cache-duration 120
                :deprecated nil))
  (setf (gethash "get_characters_character_id_wallet_journal" *endpoint-registry*)
          (list :path "/characters/{character_id}/wallet/journal/" :method :get :category
                "characters" :function-name "get-characters-character-id-wallet-journal"
                :requires-auth t :scopes '("esi-wallet.read_character_wallet.v1") :paginated t
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_characters_character_id_wallet_transactions" *endpoint-registry*)
          (list :path "/characters/{character_id}/wallet/transactions/" :method :get :category
                "characters" :function-name "get-characters-character-id-wallet-transactions"
                :requires-auth t :scopes '("esi-wallet.read_character_wallet.v1") :paginated nil
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_contracts_public_bids_contract_id" *endpoint-registry*)
          (list :path "/contracts/public/bids/{contract_id}/" :method :get :category "contracts"
                :function-name "get-contracts-public-bids-contract-id" :requires-auth nil :scopes
                'nil :paginated t :cache-duration 300 :deprecated nil))
  (setf (gethash "get_contracts_public_items_contract_id" *endpoint-registry*)
          (list :path "/contracts/public/items/{contract_id}/" :method :get :category "contracts"
                :function-name "get-contracts-public-items-contract-id" :requires-auth nil :scopes
                'nil :paginated t :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_contracts_public_region_id" *endpoint-registry*)
          (list :path "/contracts/public/{region_id}/" :method :get :category "contracts"
                :function-name "get-contracts-public-region-id" :requires-auth nil :scopes 'nil
                :paginated t :cache-duration 1800 :deprecated nil))
  (setf (gethash "get_corporation_corporation_id_mining_extractions" *endpoint-registry*)
          (list :path "/corporation/{corporation_id}/mining/extractions/" :method :get :category
                "corporation" :function-name "get-corporation-corporation-id-mining-extractions"
                :requires-auth t :scopes '("esi-industry.read_corporation_mining.v1") :paginated t
                :cache-duration 1800 :deprecated nil))
  (setf (gethash "get_corporation_corporation_id_mining_observers" *endpoint-registry*)
          (list :path "/corporation/{corporation_id}/mining/observers/" :method :get :category
                "corporation" :function-name "get-corporation-corporation-id-mining-observers"
                :requires-auth t :scopes '("esi-industry.read_corporation_mining.v1") :paginated t
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporation_corporation_id_mining_observers_observer_id" *endpoint-registry*)
          (list :path "/corporation/{corporation_id}/mining/observers/{observer_id}/" :method :get
                :category "corporation" :function-name
                "get-corporation-corporation-id-mining-observers-observer-id" :requires-auth t
                :scopes '("esi-industry.read_corporation_mining.v1") :paginated t :cache-duration
                3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/" :method :get :category "corporations"
                :function-name "get-corporations-corporation-id" :requires-auth nil :scopes 'nil
                :paginated nil :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_alliancehistory" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/alliancehistory/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-alliancehistory"
                :requires-auth nil :scopes 'nil :paginated nil :cache-duration 3600 :deprecated
                nil))
  (setf (gethash "get_corporations_corporation_id_assets" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/assets/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-assets"
                :requires-auth t :scopes '("esi-assets.read_corporation_assets.v1") :paginated t
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_blueprints" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/blueprints/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-blueprints"
                :requires-auth t :scopes '("esi-corporations.read_blueprints.v1") :paginated t
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_contacts" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/contacts/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-contacts"
                :requires-auth t :scopes '("esi-corporations.read_contacts.v1") :paginated t
                :cache-duration 300 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_contacts_labels" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/contacts/labels/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-contacts-labels"
                :requires-auth t :scopes '("esi-corporations.read_contacts.v1") :paginated nil
                :cache-duration 300 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_containers_logs" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/containers/logs/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-containers-logs"
                :requires-auth t :scopes '("esi-corporations.read_container_logs.v1") :paginated t
                :cache-duration 600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_contracts" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/contracts/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-contracts"
                :requires-auth t :scopes '("esi-contracts.read_corporation_contracts.v1")
                :paginated t :cache-duration 300 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_contracts_contract_id_bids" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/contracts/{contract_id}/bids/" :method :get
                :category "corporations" :function-name
                "get-corporations-corporation-id-contracts-contract-id-bids" :requires-auth t
                :scopes '("esi-contracts.read_corporation_contracts.v1") :paginated t
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_contracts_contract_id_items" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/contracts/{contract_id}/items/" :method :get
                :category "corporations" :function-name
                "get-corporations-corporation-id-contracts-contract-id-items" :requires-auth t
                :scopes '("esi-contracts.read_corporation_contracts.v1") :paginated nil
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_customs_offices" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/customs_offices/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-customs-offices"
                :requires-auth t :scopes '("esi-planets.read_customs_offices.v1") :paginated t
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_divisions" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/divisions/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-divisions"
                :requires-auth t :scopes '("esi-corporations.read_divisions.v1") :paginated nil
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_facilities" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/facilities/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-facilities"
                :requires-auth t :scopes '("esi-corporations.read_facilities.v1") :paginated nil
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_fw_stats" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/fw/stats/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-fw-stats"
                :requires-auth t :scopes '("esi-corporations.read_fw_stats.v1") :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_icons" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/icons/" :method :get :category "corporations"
                :function-name "get-corporations-corporation-id-icons" :requires-auth nil :scopes
                'nil :paginated nil :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_industry_jobs" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/industry/jobs/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-industry-jobs"
                :requires-auth t :scopes '("esi-industry.read_corporation_jobs.v1") :paginated t
                :cache-duration 300 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_killmails_recent" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/killmails/recent/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-killmails-recent"
                :requires-auth t :scopes '("esi-killmails.read_corporation_killmails.v1")
                :paginated t :cache-duration 300 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_medals" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/medals/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-medals"
                :requires-auth t :scopes '("esi-corporations.read_medals.v1") :paginated t
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_medals_issued" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/medals/issued/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-medals-issued"
                :requires-auth t :scopes '("esi-corporations.read_medals.v1") :paginated t
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_members" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/members/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-members"
                :requires-auth t :scopes '("esi-corporations.read_corporation_membership.v1")
                :paginated nil :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_members_limit" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/members/limit/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-members-limit"
                :requires-auth t :scopes '("esi-corporations.track_members.v1") :paginated nil
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_members_titles" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/members/titles/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-members-titles"
                :requires-auth t :scopes '("esi-corporations.read_titles.v1") :paginated nil
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_membertracking" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/membertracking/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-membertracking"
                :requires-auth t :scopes '("esi-corporations.track_members.v1") :paginated nil
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_orders" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/orders/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-orders"
                :requires-auth t :scopes '("esi-markets.read_corporation_orders.v1") :paginated t
                :cache-duration 1200 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_orders_history" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/orders/history/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-orders-history"
                :requires-auth t :scopes '("esi-markets.read_corporation_orders.v1") :paginated t
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_roles" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/roles/" :method :get :category "corporations"
                :function-name "get-corporations-corporation-id-roles" :requires-auth t :scopes
                '("esi-corporations.read_corporation_membership.v1") :paginated nil :cache-duration
                3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_roles_history" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/roles/history/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-roles-history"
                :requires-auth t :scopes '("esi-corporations.read_corporation_membership.v1")
                :paginated t :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_shareholders" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/shareholders/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-shareholders"
                :requires-auth t :scopes '("esi-wallet.read_corporation_wallets.v1") :paginated t
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_standings" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/standings/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-standings"
                :requires-auth t :scopes '("esi-corporations.read_standings.v1") :paginated t
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_starbases" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/starbases/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-starbases"
                :requires-auth t :scopes '("esi-corporations.read_starbases.v1") :paginated t
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_starbases_starbase_id" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/starbases/{starbase_id}/" :method :get
                :category "corporations" :function-name
                "get-corporations-corporation-id-starbases-starbase-id" :requires-auth t :scopes
                '("esi-corporations.read_starbases.v1") :paginated nil :cache-duration 3600
                :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_structures" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/structures/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-structures"
                :requires-auth t :scopes '("esi-corporations.read_structures.v1") :paginated t
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_titles" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/titles/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-titles"
                :requires-auth t :scopes '("esi-corporations.read_titles.v1") :paginated nil
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_wallets" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/wallets/" :method :get :category
                "corporations" :function-name "get-corporations-corporation-id-wallets"
                :requires-auth t :scopes '("esi-wallet.read_corporation_wallets.v1") :paginated nil
                :cache-duration 300 :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_wallets_division_journal" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/wallets/{division}/journal/" :method :get
                :category "corporations" :function-name
                "get-corporations-corporation-id-wallets-division-journal" :requires-auth t :scopes
                '("esi-wallet.read_corporation_wallets.v1") :paginated t :cache-duration 3600
                :deprecated nil))
  (setf (gethash "get_corporations_corporation_id_wallets_division_transactions"
                 *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/wallets/{division}/transactions/" :method
                :get :category "corporations" :function-name
                "get-corporations-corporation-id-wallets-division-transactions" :requires-auth t
                :scopes '("esi-wallet.read_corporation_wallets.v1") :paginated nil :cache-duration
                3600 :deprecated nil))
  (setf (gethash "get_corporations_npccorps" *endpoint-registry*)
          (list :path "/corporations/npccorps/" :method :get :category "corporations"
                :function-name "get-corporations-npccorps" :requires-auth nil :scopes 'nil
                :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "get_dogma_attributes" *endpoint-registry*)
          (list :path "/dogma/attributes/" :method :get :category "dogma" :function-name
                "get-dogma-attributes" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "get_dogma_attributes_attribute_id" *endpoint-registry*)
          (list :path "/dogma/attributes/{attribute_id}/" :method :get :category "dogma"
                :function-name "get-dogma-attributes-attribute-id" :requires-auth nil :scopes 'nil
                :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "get_dogma_dynamic_items_type_id_item_id" *endpoint-registry*)
          (list :path "/dogma/dynamic/items/{type_id}/{item_id}/" :method :get :category "dogma"
                :function-name "get-dogma-dynamic-items-type-id-item-id" :requires-auth nil :scopes
                'nil :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "get_dogma_effects" *endpoint-registry*)
          (list :path "/dogma/effects/" :method :get :category "dogma" :function-name
                "get-dogma-effects" :requires-auth nil :scopes 'nil :paginated nil :cache-duration
                nil :deprecated nil))
  (setf (gethash "get_dogma_effects_effect_id" *endpoint-registry*)
          (list :path "/dogma/effects/{effect_id}/" :method :get :category "dogma" :function-name
                "get-dogma-effects-effect-id" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "get_fleets_fleet_id" *endpoint-registry*)
          (list :path "/fleets/{fleet_id}/" :method :get :category "fleets" :function-name
                "get-fleets-fleet-id" :requires-auth t :scopes '("esi-fleets.read_fleet.v1")
                :paginated nil :cache-duration 5 :deprecated nil))
  (setf (gethash "get_fleets_fleet_id_members" *endpoint-registry*)
          (list :path "/fleets/{fleet_id}/members/" :method :get :category "fleets" :function-name
                "get-fleets-fleet-id-members" :requires-auth t :scopes
                '("esi-fleets.read_fleet.v1") :paginated nil :cache-duration 5 :deprecated nil))
  (setf (gethash "get_fleets_fleet_id_wings" *endpoint-registry*)
          (list :path "/fleets/{fleet_id}/wings/" :method :get :category "fleets" :function-name
                "get-fleets-fleet-id-wings" :requires-auth t :scopes '("esi-fleets.read_fleet.v1")
                :paginated nil :cache-duration 5 :deprecated nil))
  (setf (gethash "get_fw_leaderboards" *endpoint-registry*)
          (list :path "/fw/leaderboards/" :method :get :category "fw" :function-name
                "get-fw-leaderboards" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "get_fw_leaderboards_characters" *endpoint-registry*)
          (list :path "/fw/leaderboards/characters/" :method :get :category "fw" :function-name
                "get-fw-leaderboards-characters" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "get_fw_leaderboards_corporations" *endpoint-registry*)
          (list :path "/fw/leaderboards/corporations/" :method :get :category "fw" :function-name
                "get-fw-leaderboards-corporations" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "get_fw_stats" *endpoint-registry*)
          (list :path "/fw/stats/" :method :get :category "fw" :function-name "get-fw-stats"
                :requires-auth nil :scopes 'nil :paginated nil :cache-duration nil :deprecated
                nil))
  (setf (gethash "get_fw_systems" *endpoint-registry*)
          (list :path "/fw/systems/" :method :get :category "fw" :function-name "get-fw-systems"
                :requires-auth nil :scopes 'nil :paginated nil :cache-duration 1800 :deprecated
                nil))
  (setf (gethash "get_fw_wars" *endpoint-registry*)
          (list :path "/fw/wars/" :method :get :category "fw" :function-name "get-fw-wars"
                :requires-auth nil :scopes 'nil :paginated nil :cache-duration nil :deprecated
                nil))
  (setf (gethash "get_incursions" *endpoint-registry*)
          (list :path "/incursions/" :method :get :category "incursions" :function-name
                "get-incursions" :requires-auth nil :scopes 'nil :paginated nil :cache-duration 300
                :deprecated nil))
  (setf (gethash "get_industry_facilities" *endpoint-registry*)
          (list :path "/industry/facilities/" :method :get :category "industry" :function-name
                "get-industry-facilities" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_industry_systems" *endpoint-registry*)
          (list :path "/industry/systems/" :method :get :category "industry" :function-name
                "get-industry-systems" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_insurance_prices" *endpoint-registry*)
          (list :path "/insurance/prices/" :method :get :category "insurance" :function-name
                "get-insurance-prices" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_killmails_killmail_id_killmail_hash" *endpoint-registry*)
          (list :path "/killmails/{killmail_id}/{killmail_hash}/" :method :get :category
                "killmails" :function-name "get-killmails-killmail-id-killmail-hash" :requires-auth
                nil :scopes 'nil :paginated nil :cache-duration 30758400 :deprecated nil))
  (setf (gethash "get_loyalty_stores_corporation_id_offers" *endpoint-registry*)
          (list :path "/loyalty/stores/{corporation_id}/offers/" :method :get :category "loyalty"
                :function-name "get-loyalty-stores-corporation-id-offers" :requires-auth nil
                :scopes 'nil :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "get_markets_groups" *endpoint-registry*)
          (list :path "/markets/groups/" :method :get :category "markets" :function-name
                "get-markets-groups" :requires-auth nil :scopes 'nil :paginated nil :cache-duration
                nil :deprecated nil))
  (setf (gethash "get_markets_groups_market_group_id" *endpoint-registry*)
          (list :path "/markets/groups/{market_group_id}/" :method :get :category "markets"
                :function-name "get-markets-groups-market-group-id" :requires-auth nil :scopes 'nil
                :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "get_markets_prices" *endpoint-registry*)
          (list :path "/markets/prices/" :method :get :category "markets" :function-name
                "get-markets-prices" :requires-auth nil :scopes 'nil :paginated nil :cache-duration
                3600 :deprecated nil))
  (setf (gethash "get_markets_region_id_history" *endpoint-registry*)
          (list :path "/markets/{region_id}/history/" :method :get :category "markets"
                :function-name "get-markets-region-id-history" :requires-auth nil :scopes 'nil
                :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "get_markets_region_id_orders" *endpoint-registry*)
          (list :path "/markets/{region_id}/orders/" :method :get :category "markets"
                :function-name "get-markets-region-id-orders" :requires-auth nil :scopes 'nil
                :paginated t :cache-duration 300 :deprecated nil))
  (setf (gethash "get_markets_region_id_types" *endpoint-registry*)
          (list :path "/markets/{region_id}/types/" :method :get :category "markets" :function-name
                "get-markets-region-id-types" :requires-auth nil :scopes 'nil :paginated t
                :cache-duration 600 :deprecated nil))
  (setf (gethash "get_markets_structures_structure_id" *endpoint-registry*)
          (list :path "/markets/structures/{structure_id}/" :method :get :category "markets"
                :function-name "get-markets-structures-structure-id" :requires-auth t :scopes
                '("esi-markets.structure_markets.v1") :paginated t :cache-duration 300 :deprecated
                nil))
  (setf (gethash "get_route_origin_destination" *endpoint-registry*)
          (list :path "/route/{origin}/{destination}/" :method :get :category "route"
                :function-name "get-route-origin-destination" :requires-auth nil :scopes 'nil
                :paginated nil :cache-duration 86400 :deprecated nil))
  (setf (gethash "get_sovereignty_campaigns" *endpoint-registry*)
          (list :path "/sovereignty/campaigns/" :method :get :category "sovereignty" :function-name
                "get-sovereignty-campaigns" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration 5 :deprecated nil))
  (setf (gethash "get_sovereignty_map" *endpoint-registry*)
          (list :path "/sovereignty/map/" :method :get :category "sovereignty" :function-name
                "get-sovereignty-map" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_sovereignty_structures" *endpoint-registry*)
          (list :path "/sovereignty/structures/" :method :get :category "sovereignty"
                :function-name "get-sovereignty-structures" :requires-auth nil :scopes 'nil
                :paginated nil :cache-duration 120 :deprecated nil))
  (setf (gethash "get_status" *endpoint-registry*)
          (list :path "/status/" :method :get :category "status" :function-name "get-status"
                :requires-auth nil :scopes 'nil :paginated nil :cache-duration 30 :deprecated nil))
  (setf (gethash "get_universe_ancestries" *endpoint-registry*)
          (list :path "/universe/ancestries/" :method :get :category "universe" :function-name
                "get-universe-ancestries" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "get_universe_asteroid_belts_asteroid_belt_id" *endpoint-registry*)
          (list :path "/universe/asteroid_belts/{asteroid_belt_id}/" :method :get :category
                "universe" :function-name "get-universe-asteroid-belts-asteroid-belt-id"
                :requires-auth nil :scopes 'nil :paginated nil :cache-duration nil :deprecated
                nil))
  (setf (gethash "get_universe_bloodlines" *endpoint-registry*)
          (list :path "/universe/bloodlines/" :method :get :category "universe" :function-name
                "get-universe-bloodlines" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "get_universe_categories" *endpoint-registry*)
          (list :path "/universe/categories/" :method :get :category "universe" :function-name
                "get-universe-categories" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "get_universe_categories_category_id" *endpoint-registry*)
          (list :path "/universe/categories/{category_id}/" :method :get :category "universe"
                :function-name "get-universe-categories-category-id" :requires-auth nil :scopes
                'nil :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "get_universe_constellations" *endpoint-registry*)
          (list :path "/universe/constellations/" :method :get :category "universe" :function-name
                "get-universe-constellations" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "get_universe_constellations_constellation_id" *endpoint-registry*)
          (list :path "/universe/constellations/{constellation_id}/" :method :get :category
                "universe" :function-name "get-universe-constellations-constellation-id"
                :requires-auth nil :scopes 'nil :paginated nil :cache-duration nil :deprecated
                nil))
  (setf (gethash "get_universe_factions" *endpoint-registry*)
          (list :path "/universe/factions/" :method :get :category "universe" :function-name
                "get-universe-factions" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "get_universe_graphics" *endpoint-registry*)
          (list :path "/universe/graphics/" :method :get :category "universe" :function-name
                "get-universe-graphics" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "get_universe_graphics_graphic_id" *endpoint-registry*)
          (list :path "/universe/graphics/{graphic_id}/" :method :get :category "universe"
                :function-name "get-universe-graphics-graphic-id" :requires-auth nil :scopes 'nil
                :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "get_universe_groups" *endpoint-registry*)
          (list :path "/universe/groups/" :method :get :category "universe" :function-name
                "get-universe-groups" :requires-auth nil :scopes 'nil :paginated t :cache-duration
                nil :deprecated nil))
  (setf (gethash "get_universe_groups_group_id" *endpoint-registry*)
          (list :path "/universe/groups/{group_id}/" :method :get :category "universe"
                :function-name "get-universe-groups-group-id" :requires-auth nil :scopes 'nil
                :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "get_universe_moons_moon_id" *endpoint-registry*)
          (list :path "/universe/moons/{moon_id}/" :method :get :category "universe" :function-name
                "get-universe-moons-moon-id" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "get_universe_planets_planet_id" *endpoint-registry*)
          (list :path "/universe/planets/{planet_id}/" :method :get :category "universe"
                :function-name "get-universe-planets-planet-id" :requires-auth nil :scopes 'nil
                :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "get_universe_races" *endpoint-registry*)
          (list :path "/universe/races/" :method :get :category "universe" :function-name
                "get-universe-races" :requires-auth nil :scopes 'nil :paginated nil :cache-duration
                nil :deprecated nil))
  (setf (gethash "get_universe_regions" *endpoint-registry*)
          (list :path "/universe/regions/" :method :get :category "universe" :function-name
                "get-universe-regions" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "get_universe_regions_region_id" *endpoint-registry*)
          (list :path "/universe/regions/{region_id}/" :method :get :category "universe"
                :function-name "get-universe-regions-region-id" :requires-auth nil :scopes 'nil
                :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "get_universe_schematics_schematic_id" *endpoint-registry*)
          (list :path "/universe/schematics/{schematic_id}/" :method :get :category "universe"
                :function-name "get-universe-schematics-schematic-id" :requires-auth nil :scopes
                'nil :paginated nil :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_universe_stargates_stargate_id" *endpoint-registry*)
          (list :path "/universe/stargates/{stargate_id}/" :method :get :category "universe"
                :function-name "get-universe-stargates-stargate-id" :requires-auth nil :scopes 'nil
                :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "get_universe_stars_star_id" *endpoint-registry*)
          (list :path "/universe/stars/{star_id}/" :method :get :category "universe" :function-name
                "get-universe-stars-star-id" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "get_universe_stations_station_id" *endpoint-registry*)
          (list :path "/universe/stations/{station_id}/" :method :get :category "universe"
                :function-name "get-universe-stations-station-id" :requires-auth nil :scopes 'nil
                :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "get_universe_structures" *endpoint-registry*)
          (list :path "/universe/structures/" :method :get :category "universe" :function-name
                "get-universe-structures" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_universe_structures_structure_id" *endpoint-registry*)
          (list :path "/universe/structures/{structure_id}/" :method :get :category "universe"
                :function-name "get-universe-structures-structure-id" :requires-auth t :scopes
                '("esi-universe.read_structures.v1") :paginated nil :cache-duration 3600
                :deprecated nil))
  (setf (gethash "get_universe_system_jumps" *endpoint-registry*)
          (list :path "/universe/system_jumps/" :method :get :category "universe" :function-name
                "get-universe-system-jumps" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_universe_system_kills" *endpoint-registry*)
          (list :path "/universe/system_kills/" :method :get :category "universe" :function-name
                "get-universe-system-kills" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "get_universe_systems" *endpoint-registry*)
          (list :path "/universe/systems/" :method :get :category "universe" :function-name
                "get-universe-systems" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "get_universe_systems_system_id" *endpoint-registry*)
          (list :path "/universe/systems/{system_id}/" :method :get :category "universe"
                :function-name "get-universe-systems-system-id" :requires-auth nil :scopes 'nil
                :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "get_universe_types" *endpoint-registry*)
          (list :path "/universe/types/" :method :get :category "universe" :function-name
                "get-universe-types" :requires-auth nil :scopes 'nil :paginated t :cache-duration
                nil :deprecated nil))
  (setf (gethash "get_universe_types_type_id" *endpoint-registry*)
          (list :path "/universe/types/{type_id}/" :method :get :category "universe" :function-name
                "get-universe-types-type-id" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "get_wars" *endpoint-registry*)
          (list :path "/wars/" :method :get :category "wars" :function-name "get-wars"
                :requires-auth nil :scopes 'nil :paginated nil :cache-duration 3600 :deprecated
                nil))
  (setf (gethash "get_wars_war_id" *endpoint-registry*)
          (list :path "/wars/{war_id}/" :method :get :category "wars" :function-name
                "get-wars-war-id" :requires-auth nil :scopes 'nil :paginated nil :cache-duration
                3600 :deprecated nil))
  (setf (gethash "get_wars_war_id_killmails" *endpoint-registry*)
          (list :path "/wars/{war_id}/killmails/" :method :get :category "wars" :function-name
                "get-wars-war-id-killmails" :requires-auth nil :scopes 'nil :paginated t
                :cache-duration 3600 :deprecated nil))
  (setf (gethash "post_characters_affiliation" *endpoint-registry*)
          (list :path "/characters/affiliation/" :method :post :category "characters"
                :function-name "post-characters-affiliation" :requires-auth nil :scopes 'nil
                :paginated nil :cache-duration 3600 :deprecated nil))
  (setf (gethash "post_characters_character_id_assets_locations" *endpoint-registry*)
          (list :path "/characters/{character_id}/assets/locations/" :method :post :category
                "characters" :function-name "post-characters-character-id-assets-locations"
                :requires-auth t :scopes '("esi-assets.read_assets.v1") :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "post_characters_character_id_assets_names" *endpoint-registry*)
          (list :path "/characters/{character_id}/assets/names/" :method :post :category
                "characters" :function-name "post-characters-character-id-assets-names"
                :requires-auth t :scopes '("esi-assets.read_assets.v1") :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "post_characters_character_id_contacts" *endpoint-registry*)
          (list :path "/characters/{character_id}/contacts/" :method :post :category "characters"
                :function-name "post-characters-character-id-contacts" :requires-auth t :scopes
                '("esi-characters.write_contacts.v1") :paginated nil :cache-duration nil
                :deprecated nil))
  (setf (gethash "post_characters_character_id_cspa" *endpoint-registry*)
          (list :path "/characters/{character_id}/cspa/" :method :post :category "characters"
                :function-name "post-characters-character-id-cspa" :requires-auth t :scopes
                '("esi-characters.read_contacts.v1") :paginated nil :cache-duration nil :deprecated
                nil))
  (setf (gethash "post_characters_character_id_fittings" *endpoint-registry*)
          (list :path "/characters/{character_id}/fittings/" :method :post :category "characters"
                :function-name "post-characters-character-id-fittings" :requires-auth t :scopes
                '("esi-fittings.write_fittings.v1") :paginated nil :cache-duration nil :deprecated
                nil))
  (setf (gethash "post_characters_character_id_mail" *endpoint-registry*)
          (list :path "/characters/{character_id}/mail/" :method :post :category "characters"
                :function-name "post-characters-character-id-mail" :requires-auth t :scopes
                '("esi-mail.send_mail.v1") :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "post_characters_character_id_mail_labels" *endpoint-registry*)
          (list :path "/characters/{character_id}/mail/labels/" :method :post :category
                "characters" :function-name "post-characters-character-id-mail-labels"
                :requires-auth t :scopes '("esi-mail.organize_mail.v1") :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "post_corporations_corporation_id_assets_locations" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/assets/locations/" :method :post :category
                "corporations" :function-name "post-corporations-corporation-id-assets-locations"
                :requires-auth t :scopes '("esi-assets.read_corporation_assets.v1") :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "post_corporations_corporation_id_assets_names" *endpoint-registry*)
          (list :path "/corporations/{corporation_id}/assets/names/" :method :post :category
                "corporations" :function-name "post-corporations-corporation-id-assets-names"
                :requires-auth t :scopes '("esi-assets.read_corporation_assets.v1") :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "post_fleets_fleet_id_members" *endpoint-registry*)
          (list :path "/fleets/{fleet_id}/members/" :method :post :category "fleets" :function-name
                "post-fleets-fleet-id-members" :requires-auth t :scopes
                '("esi-fleets.write_fleet.v1") :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "post_fleets_fleet_id_wings" *endpoint-registry*)
          (list :path "/fleets/{fleet_id}/wings/" :method :post :category "fleets" :function-name
                "post-fleets-fleet-id-wings" :requires-auth t :scopes
                '("esi-fleets.write_fleet.v1") :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "post_fleets_fleet_id_wings_wing_id_squads" *endpoint-registry*)
          (list :path "/fleets/{fleet_id}/wings/{wing_id}/squads/" :method :post :category "fleets"
                :function-name "post-fleets-fleet-id-wings-wing-id-squads" :requires-auth t :scopes
                '("esi-fleets.write_fleet.v1") :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "post_ui_autopilot_waypoint" *endpoint-registry*)
          (list :path "/ui/autopilot/waypoint/" :method :post :category "ui" :function-name
                "post-ui-autopilot-waypoint" :requires-auth t :scopes '("esi-ui.write_waypoint.v1")
                :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "post_ui_openwindow_contract" *endpoint-registry*)
          (list :path "/ui/openwindow/contract/" :method :post :category "ui" :function-name
                "post-ui-openwindow-contract" :requires-auth t :scopes '("esi-ui.open_window.v1")
                :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "post_ui_openwindow_information" *endpoint-registry*)
          (list :path "/ui/openwindow/information/" :method :post :category "ui" :function-name
                "post-ui-openwindow-information" :requires-auth t :scopes
                '("esi-ui.open_window.v1") :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "post_ui_openwindow_marketdetails" *endpoint-registry*)
          (list :path "/ui/openwindow/marketdetails/" :method :post :category "ui" :function-name
                "post-ui-openwindow-marketdetails" :requires-auth t :scopes
                '("esi-ui.open_window.v1") :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "post_ui_openwindow_newmail" *endpoint-registry*)
          (list :path "/ui/openwindow/newmail/" :method :post :category "ui" :function-name
                "post-ui-openwindow-newmail" :requires-auth t :scopes '("esi-ui.open_window.v1")
                :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "post_universe_ids" *endpoint-registry*)
          (list :path "/universe/ids/" :method :post :category "universe" :function-name
                "post-universe-ids" :requires-auth nil :scopes 'nil :paginated nil :cache-duration
                nil :deprecated nil))
  (setf (gethash "post_universe_names" *endpoint-registry*)
          (list :path "/universe/names/" :method :post :category "universe" :function-name
                "post-universe-names" :requires-auth nil :scopes 'nil :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "put_characters_character_id_calendar_event_id" *endpoint-registry*)
          (list :path "/characters/{character_id}/calendar/{event_id}/" :method :put :category
                "characters" :function-name "put-characters-character-id-calendar-event-id"
                :requires-auth t :scopes '("esi-calendar.respond_calendar_events.v1") :paginated
                nil :cache-duration 5 :deprecated nil))
  (setf (gethash "put_characters_character_id_contacts" *endpoint-registry*)
          (list :path "/characters/{character_id}/contacts/" :method :put :category "characters"
                :function-name "put-characters-character-id-contacts" :requires-auth t :scopes
                '("esi-characters.write_contacts.v1") :paginated nil :cache-duration nil
                :deprecated nil))
  (setf (gethash "put_characters_character_id_mail_mail_id" *endpoint-registry*)
          (list :path "/characters/{character_id}/mail/{mail_id}/" :method :put :category
                "characters" :function-name "put-characters-character-id-mail-mail-id"
                :requires-auth t :scopes '("esi-mail.organize_mail.v1") :paginated nil
                :cache-duration nil :deprecated nil))
  (setf (gethash "put_fleets_fleet_id" *endpoint-registry*)
          (list :path "/fleets/{fleet_id}/" :method :put :category "fleets" :function-name
                "put-fleets-fleet-id" :requires-auth t :scopes '("esi-fleets.write_fleet.v1")
                :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "put_fleets_fleet_id_members_member_id" *endpoint-registry*)
          (list :path "/fleets/{fleet_id}/members/{member_id}/" :method :put :category "fleets"
                :function-name "put-fleets-fleet-id-members-member-id" :requires-auth t :scopes
                '("esi-fleets.write_fleet.v1") :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "put_fleets_fleet_id_squads_squad_id" *endpoint-registry*)
          (list :path "/fleets/{fleet_id}/squads/{squad_id}/" :method :put :category "fleets"
                :function-name "put-fleets-fleet-id-squads-squad-id" :requires-auth t :scopes
                '("esi-fleets.write_fleet.v1") :paginated nil :cache-duration nil :deprecated nil))
  (setf (gethash "put_fleets_fleet_id_wings_wing_id" *endpoint-registry*)
          (list :path "/fleets/{fleet_id}/wings/{wing_id}/" :method :put :category "fleets"
                :function-name "put-fleets-fleet-id-wings-wing-id" :requires-auth t :scopes
                '("esi-fleets.write_fleet.v1") :paginated nil :cache-duration nil :deprecated nil))
  (log-info "Endpoint registry populated: ~D endpoints" (hash-table-count *endpoint-registry*))
  *endpoint-registry*)


(defun lookup-endpoint (operation-id)
  "Look up endpoint metadata by operation ID.

OPERATION-ID: String (e.g., \"get_characters_character_id\")

Returns a plist of endpoint metadata, or NIL."
  (gethash operation-id *endpoint-registry*))


(defun list-endpoints-by-category (category)
  "List all operation IDs in a given category.

CATEGORY: Category string (e.g., \"characters\")

Returns a list of operation ID strings."
  (loop for op-id being the hash-keys of *endpoint-registry* using (hash-value meta)
        when (string-equal (getf meta :category) category)
        collect op-id))

