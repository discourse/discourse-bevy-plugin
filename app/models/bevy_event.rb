# frozen_string_literal: true

class BevyEvent < ActiveRecord::Base
  validates :bevy_event_id, presence: true, uniqueness: true
  validates :bevy_updated_ts, presence: true

  belongs_to :post, dependent: :destroy
end

# == Schema Information
#
# Table name: bevy_events
#
#  id              :bigint           not null, primary key
#  bevy_updated_ts :datetime         not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  event_id        :integer          not null
#
# Indexes
#
#  index_bevy_events_on_id_and_timestamp  (event_id,bevy_updated_ts)
#
