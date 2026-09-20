defmodule PiFi.Playback do
  @moduledoc """
  What the device plays, and the controls for it.

  Each control is a generic action, in the same way that `PiFi.Device` reports
  the machine. An API extension such as `ash_json_api` serves an action and not a
  function, and a policy guards an action and not a function. The internal API and
  the external API then have one shape.

  `PiFi.Player` is the process. It owns the pipeline, the count of tries, and
  the monitor, and none of that belongs in an action. `PiFi.Playback.Player`
  declares the actions, and each one calls that process.
  """

  use Ash.Domain, otp_app: :pifi

  resources do
    resource PiFi.Playback.Facet do
      define :list_facets, action: :read
      define :get_facet, action: :read, get_by: [:id]
      define :facets_of_key, action: :by_key, args: [:key]
      define :upsert_facet, action: :upsert
      define :destroy_facet, action: :destroy
      define :destroy_orphan_facets, action: :destroy_orphans
    end

    resource PiFi.Playback.ItemFacet do
      define :list_item_facets, action: :read
      define :link_facet, action: :upsert
      define :unlink_facet, action: :destroy
    end

    resource PiFi.Playback.Item do
      define :list_items, action: :read
      define :get_item, action: :read, get_by: [:id]
      define :items_of_parent, action: :by_parent, args: [:parent_id]
      define :items_of_facet, action: :by_facet, args: [:facet_id]
      define :items_of_source, action: :by_source, args: [:source]
      define :favourite_items, action: :favourites
      define :items_marked_for_audio, action: :marked_for_audio, args: [:source]
      define :items_holding_audio, action: :holding_audio
      define :upsert_item, action: :upsert
      define :set_favourite, action: :set_favourite
      define :clear_favourite, action: :clear_favourite
      define :store_position, action: :store_position
      define :mark_played, action: :mark_played
      define :mark_started, action: :mark_started
      define :history, action: :history
      define :clear_played, action: :clear_played
      define :destroy_item, action: :destroy
      define :remove_source_cache, action: :remove_cache, args: [:source]
    end

    resource PiFi.Playback.Playlist do
      define :list_playlists, action: :in_order
      define :get_playlist, action: :read, get_by: [:id]
      define :create_playlist, action: :create, args: [:name]
      define :rename_playlist, action: :rename, args: [:name]
      define :destroy_playlist, action: :destroy
      define :add_to_playlist, action: :add, args: [:playlist_id, :item_ids]
      define :playlist_item_ids, action: :item_ids, args: [:playlist_id]
    end

    resource PiFi.Playback.PlaylistEntry do
      define :playlist_entries, action: :in_order, args: [:playlist_id]
      define :remove_playlist_entry, action: :remove, args: [:id]
      define :reorder_playlist_entry, action: :reorder, args: [:id, :position]
    end

    resource PiFi.Playback.Queue do
      define :queue, action: :in_order
      # An empty queue plays nothing, and that is a normal state and not an error, so
      # the bang gives `nil` in the place of a `NotFound`.
      define :queue_playing, action: :playing, not_found_error?: false
      define :replace_queue, action: :replace, args: [:item_ids]
      define :append_to_queue, action: :append, args: [:item_ids]
      define :move_queue, action: :move, args: [:direction]
      define :queue_next_up, action: :next_up
      define :remove_from_queue, action: :remove, args: [:id]
      define :reorder_queue, action: :reorder, args: [:id, :position]
      define :clear_queue, action: :clear
    end

    resource PiFi.Playback.Player do
      define :state, action: :state
      define :play, action: :play, args: [:item_ids]
      define :stop, action: :stop
      define :pause, action: :pause, args: [:paused?]
      define :next, action: :next
      define :previous, action: :previous
      define :skip, action: :skip, args: [:ms]
      define :standby, action: :standby, args: [:entered?]
      define :standby_minutes, action: :standby_minutes
      define :set_standby_minutes, action: :set_standby_minutes, args: [:minutes]
      define :screen_blank_seconds, action: :screen_blank_seconds
      define :set_screen_blank_seconds, action: :set_screen_blank_seconds, args: [:seconds]
      define :enable_source, action: :enable_source, args: [:source, :enabled?]
      define :output, action: :output
      define :select_output, action: :select_output, args: [:id]
      define :volume, action: :volume
      define :set_volume, action: :set_volume, args: [:percent]
      define :enable_volume, action: :enable_volume, args: [:enabled?]
    end
  end
end
