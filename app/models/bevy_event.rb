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
#  bevy_event_id   :integer          not null
#  post_id         :integer
#
# Indexes
#
#  index_bevy_events_on_id_and_timestamp  (bevy_event_id,bevy_updated_ts)
#  index_bevy_events_on_post_id           (post_id)
#
