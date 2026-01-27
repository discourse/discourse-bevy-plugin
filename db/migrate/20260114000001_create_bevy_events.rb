# frozen_string_literal: true

class CreateBevyEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :bevy_events do |t|
      t.integer :bevy_event_id, null: false
      t.datetime :bevy_updated_ts, null: false
      t.integer :post_id
      t.timestamps
    end

    add_index :bevy_events,
              %i[bevy_event_id bevy_updated_ts],
              name: "index_bevy_events_on_id_and_timestamp"
    add_index :bevy_events, :post_id
  end
end
