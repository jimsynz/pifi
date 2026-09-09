defmodule MyHiFi.Playback do
  @moduledoc """
  What the device plays, and the controls for it.

  Each control is a generic action, in the same way that `MyHiFi.Device` reports
  the machine. An API extension such as `ash_json_api` serves an action and not a
  function, and a policy guards an action and not a function. The internal API and
  the external API then have one shape.

  `MyHiFi.Player` is the process. It holds the pipeline, the count of tries, and
  the monitor, and none of that belongs in an action. `MyHiFi.Playback.Player`
  holds the actions, and each one calls that process.
  """

  use Ash.Domain, otp_app: :my_hi_fi

  resources do
    resource MyHiFi.Playback.Facet do
      define :list_facets, action: :read
      define :get_facet, action: :read, get_by: [:id]
      define :facets_of_key, action: :by_key, args: [:key]
      define :upsert_facet, action: :upsert
      define :destroy_facet, action: :destroy
      define :destroy_orphan_facets, action: :destroy_orphans
    end

    resource MyHiFi.Playback.ItemFacet do
      define :list_item_facets, action: :read
      define :link_facet, action: :upsert
      define :unlink_facet, action: :destroy
    end

    resource MyHiFi.Playback.Item do
      define :list_items, action: :read
      define :get_item, action: :read, get_by: [:id]
      define :items_of_parent, action: :by_parent, args: [:parent_id]
      define :items_of_source, action: :by_source, args: [:source]
      define :favourite_items, action: :favourites
      define :items_marked_for_audio, action: :marked_for_audio, args: [:source]
      define :items_holding_audio, action: :holding_audio
      define :upsert_item, action: :upsert
      define :set_favourite, action: :set_favourite
      define :clear_favourite, action: :clear_favourite
      define :store_position, action: :store_position
      define :mark_played, action: :mark_played
      define :clear_played, action: :clear_played
      define :destroy_item, action: :destroy
    end

    resource MyHiFi.Playback.Queue do
      define :queue, action: :in_order
      # An empty queue plays nothing, and that is a normal state and not an error, so
      # the bang gives `nil` in the place of a `NotFound`.
      define :queue_playing, action: :playing, not_found_error?: false
      define :replace_queue, action: :replace, args: [:item_ids]
      define :append_to_queue, action: :append, args: [:item_ids]
      define :move_queue, action: :move, args: [:direction]
      define :queue_next_up, action: :next_up
      define :remove_from_queue, action: :remove, args: [:id]
      define :clear_queue, action: :clear
    end

    resource MyHiFi.Playback.Player do
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
      define :enable_source, action: :enable_source, args: [:source, :enabled?]
      define :output, action: :output
      define :select_output, action: :select_output, args: [:id]
    end
  end
end
