# frozen_string_literal: true

require "rails_helper"

describe BevyPlugin::JmesTagExtractor do
  let(:bevy_event_payload) do
    JSON.parse(File.read(File.join(__dir__, "../fixtures/json/bevy_event_payload.json")))
  end

  let(:sample_event_data) { bevy_event_payload.first["data"].first.deep_symbolize_keys }

  before { SiteSetting.bevy_plugin_enabled = true }

  describe ".extract_tags_from_data" do
    context "with no rules configured" do
      before { SiteSetting.bevy_events_tag_rules = "" }

      it "returns empty array" do
        tags = described_class.extract_tags_from_data(sample_event_data)
        expect(tags).to eq([])
      end
    end

    context "with simple field existence checks" do
      before { SiteSetting.bevy_events_tag_rules = "has-venue,venue_name" }

      it "adds tag when field has a value" do
        tags = described_class.extract_tags_from_data(sample_event_data)
        expect(tags).to include("has-venue")
      end

      it "does not add tag when field is missing" do
        data = sample_event_data.dup
        data.delete(:venue_name)
        tags = described_class.extract_tags_from_data(data)
        expect(tags).not_to include("has-venue")
      end
    end

    context "with multiple rules" do
      before do
        SiteSetting.bevy_events_tag_rules =
          "argentina,chapter.country == 'AR'|has-venue,venue_name|virtual,event_type_title == 'Virtual Event type'"
      end

      it "evaluates all rules and adds matching tags" do
        tags = described_class.extract_tags_from_data(sample_event_data)
        expect(tags).to include("argentina", "has-venue", "virtual")
      end

      it "only adds tags where expressions are truthy" do
        SiteSetting.bevy_events_tag_rules =
          "argentina,chapter.country == 'AR'|usa,chapter.country == 'US'"
        tags = described_class.extract_tags_from_data(sample_event_data)
        expect(tags).to include("argentina")
        expect(tags).not_to include("usa")
      end
    end

    context "with complex JMESPath expressions" do
      before do
        # This example uses nested field access and array indexing
        SiteSetting.bevy_events_tag_rules = "leader,chapter.chapter_team[0].title"
      end

      it "extracts from nested objects" do
        tags = described_class.extract_tags_from_data(sample_event_data)
        expect(tags).to include("leader")
      end

      it "does not add tag when nested value is missing" do
        data = sample_event_data.dup
        data[:chapter][:chapter_team][0][:title] = nil
        tags = described_class.extract_tags_from_data(data)
        expect(tags).not_to include("leader")
      end
    end

    context "with nested field access" do
      before { SiteSetting.bevy_events_tag_rules = "catamarca,chapter.city == 'Catamarca'" }

      it "accesses nested fields correctly" do
        tags = described_class.extract_tags_from_data(sample_event_data)
        expect(tags).to include("catamarca")
      end
    end

    describe "edge cases" do
      it "handles false boolean results" do
        SiteSetting.bevy_events_tag_rules = "never,`false`"
        tags = described_class.extract_tags_from_data(sample_event_data)
        expect(tags).not_to include("never")
      end

      it "handles null results" do
        SiteSetting.bevy_events_tag_rules = "missing,nonexistent_field"
        tags = described_class.extract_tags_from_data(sample_event_data)
        expect(tags).not_to include("missing")
      end

      it "handles empty string results" do
        data = sample_event_data.merge(empty_field: "")
        SiteSetting.bevy_events_tag_rules = "empty,empty_field"
        tags = described_class.extract_tags_from_data(data)
        # Empty string is truthy in JMESPath
        expect(tags).to include("empty")
      end
    end

    context "with spaces in configuration" do
      it "handles excessive whitespace" do
        SiteSetting.bevy_events_tag_rules =
          "  argentina  ,  chapter.country == 'AR'  |  has-venue  ,  venue_name  "
        tags = described_class.extract_tags_from_data(sample_event_data)
        expect(tags).to include("argentina", "has-venue")
      end

      it "works correctly without spaces" do
        SiteSetting.bevy_events_tag_rules = "argentina,chapter.country == 'AR'|has-venue,venue_name"
        tags = described_class.extract_tags_from_data(sample_event_data)
        expect(tags).to include("argentina", "has-venue")
      end
    end
  end
end
