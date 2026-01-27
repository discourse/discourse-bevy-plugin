# Discourse Bevy Plugin

Integration with Bevy event management platform to automatically create and sync event topics in Discourse.

## Features

### Event Management
- Receives webhooks from Bevy when events are created or updated
- Automatically creates Discourse topics for published events (Draft events are ignored)
- Updates existing topics when Bevy events are modified
- Event deduplication using timestamps to prevent stale updates
- Only processes events with "Published" status
- Integrates with discourse-post-event plugin to create calendar events

### Attendee Syncing
- Syncs attendee registrations from Bevy to discourse-post-event
- Maps Bevy attendee statuses to Discourse invitee statuses:
  - `registered` → `going`
  - `deleted` → `not_going`
- Matches attendees by email address to Discourse users
- Automatically creates/updates invitee records for discourse-post-event

### User Matching
- Attempts to match event creators by email and posts as that user
- Falls back to system user if email doesn't match any Discourse user
- Supports custom user identification via `published_by` field in webhook payload

### Tag Extraction
- Configurable tag extraction using JMESPath expressions
- Extract tags from any field in the Bevy event payload
- Automatically applies tags to created/updated topics

### Content Generation
- Creates rich event topics with:
  - Event title as the topic title
  - Event description and short description
  - Event image (if available)
  - Event dates (start and end)
  - Location information (venue name and address)
  - Event type and chapter information
  - discourse-post-event integration with proper date/time formatting
  - Link back to the Bevy event page

### Security
- API key authentication via `X-BEVY-SECRET` header
- Validates all incoming webhook requests
- Configurable webhook API key

## Configuration

### Required Settings

1. Go to **Admin → Settings → Plugins → bevy_plugin**
2. Enable the plugin: Check `bevy_plugin_enabled`
3. Set webhook API key: Enter a secure random string in `bevy_webhook_api_key`
4. Configure category: Select the category for event topics in `bevy_webhook_category_id`

### Optional Settings

- **Tag Rules** (`bevy_events_tag_rules`): JMESPath expressions to extract tags from event data
  - Example: `chapter.city` to tag events with their chapter city
  - Multiple rules can be defined (see Tag Extraction section below)

## Bevy Webhook Setup

1. In your Bevy admin panel, go to **Settings → Webhooks**
2. Create a new webhook with the following settings:
   - **URL**: `https://your-discourse-url.com/bevy/webhooks`
   - **Events**: Select both:
     - "Event updates" (for event creation/updates)
     - "Attendee updates" (for registration syncing)
   - **Authentication**: Add a custom header:
     - Header name: `X-BEVY-SECRET`
     - Header value: The API key you configured in plugin settings
   - **Extra Data Fields**: Request Bevy customer service to include the `published_by` field to enable user matching by email when creating bevy events

3. Test the webhook to ensure it's working correctly

## How It Works

### Event Webhooks

When Bevy sends a webhook for a published event:

1. **Authentication**: Validates the `X-BEVY-SECRET` header matches your configured API key
2. **Deduplication**: Checks if event exists and compares `updated_ts` to prevent processing stale webhooks
3. **User Lookup**: Attempts to find a Discourse user matching the `published_by.email` (if the field is included)
4. **Topic Creation/Update**:
   - **New events**: Creates a new topic with event details
   - **Existing events**: Updates the existing topic (title, content, tags)
5. **Post Event Integration**: Adds discourse-post-event markup with dates and timezone
6. **Tag Application**: Applies tags extracted via JMESPath rules
7. **Database Tracking**: Records the event with its `bevy_event_id` and `updated_ts` for future updates

### Attendee Webhooks

When Bevy sends a webhook for attendee registrations:

1. **Authentication**: Validates the webhook signature
2. **Event Lookup**: Finds the corresponding Discourse topic and post event
3. **User Matching**: Matches attendee emails to Discourse user accounts
4. **Status Mapping**: Converts Bevy statuses to discourse-post-event invitee statuses
5. **Bulk Sync**: Uses `upsert_all` to efficiently sync all attendees for the event

### Event Deduplication

The plugin tracks events using two fields:
- `bevy_event_id`: The unique event ID from Bevy
- `bevy_updated_ts`: The timestamp of the last update from Bevy

When a webhook is received:
- If the event doesn't exist, it's created
- If the event exists and the new `updated_ts` is newer, it's updated
- If the event exists and the new `updated_ts` is older or equal, the webhook is ignored (returns 200 OK with "Event already up to date" message)

This prevents race conditions and ensures only the latest event data is used.

## Tag Extraction

The plugin supports extracting tags from Bevy event data using JMESPath expressions. Configure rules in the `bevy_events_tag_rules` setting.

### Configuration Format

The setting uses a pipe-separated format where each rule consists of a tag name and a JMESPath expression separated by a comma:

```
TagName1,expression1|TagName2,expression2|TagName3,expression3
```

**Structure:**
- Multiple rules separated by `|` (pipe)
- Each rule has two parts separated by `,` (comma):
  - **Tag name**: The literal tag that will be added to the topic (e.g., "dev", "production", "virtual")
  - **JMESPath expression**: A boolean test or value extraction - if the result is truthy, the tag name is added
- **Note**: Whitespace around separators and values is automatically stripped, so spacing is flexible

**How it works:**
The expression is evaluated against the event data. If it returns a truthy value (not `false`, `null`, or empty), the **tag name** is added to the topic.

### Example Configurations

**Add "test" tag for test events:**
```
test,contains(chapter.chapter_location, 'Test')
```
Result: If chapter location contains "Test", adds tag "test"

**Add environment tags based on location:**
```
staging,contains(chapter.chapter_location, 'Staging')|production,contains(chapter.chapter_location, 'Production')
```
Result: Adds "staging" tag for staging chapters, "production" tag for production chapters

**Add "virtual" tag for virtual events:**
```
virtual,event_type_title == 'Virtual Event type'
```
Result: If event type is "Virtual Event type", adds tag "virtual"

**Add country tags:**
```
usa,chapter.country == 'US'|canada,chapter.country == 'CA'|uk,chapter.country == 'GB'
```
Result: Adds country tag based on chapter location

**Add tag if field exists and has a value:**
```
has-venue,venue_name
```
Result: If venue_name is not empty/null, adds tag "has-venue"

**Complex: Check nested team data:**
```
has-leader,chapter.chapter_team[0].title
```
Result: If the first team member has a title, adds tag "has-leader"

### Tag Processing

- All tags are automatically lowercased and sanitized
- Duplicate tags are removed
- Empty/null values are filtered out
- Tags are created in Discourse if they don't exist
- Existing topics get their tags updated when the event is updated

## Requirements

### Required Plugins
- **discourse-calendar**: For calendar event integration and attendee management

### Bevy Configuration
- Webhook support enabled in your Bevy account
- Access to Bevy admin panel to configure webhooks
- Events must include the `published_by` field for user matching

## Troubleshooting

### Webhooks not being received

1. Check that the plugin is enabled in settings
2. Verify the webhook URL is correct: `https://your-site.com/bevy/webhooks`
3. Check your Discourse logs for webhook requests: `Admin → Logs → Staff Action Logs`
4. Verify ngrok or your proxy is properly forwarding requests (if testing locally)

### Authentication failures

1. Verify the `X-BEVY-SECRET` header value matches your `bevy_webhook_api_key` setting exactly
2. Check for extra whitespace or encoding issues in the API key
3. Review logs for "Unauthorized" or "Webhook not configured" errors

### Topics not being created

1. Verify the event status is "Published" (Draft events are skipped)
2. Check that `bevy_webhook_category_id` is set to a valid category
3. Ensure discourse-post-event plugin is installed and enabled
4. Review Rails logs for specific error messages

### Attendees not syncing

1. Verify the discourse-post-event plugin is installed
2. Check that the event has been created (attendee sync requires an existing event)
3. Ensure attendee emails match Discourse user emails
4. Review logs for "No post found for event" warnings

### Events not updating

1. Check that the `updated_ts` in the webhook is newer than the stored timestamp
2. The plugin intentionally ignores webhooks with older timestamps to prevent race conditions
3. If an event isn't updating, it may be receiving a stale webhook - check Bevy's webhook delivery logs

## Development

### Running Tests
From your discourse directory run:

```bash
LOAD_Plugins=1 bundle exec rspec plugins/discourse-bevy-plugin/spec
```

### Database Models

The plugin creates one custom model:

**BevyEvent**
- `bevy_event_id` (integer): The Bevy event ID
- `post_id` (integer): The Discourse post ID for the event topic
- `bevy_updated_ts` (datetime): The last update timestamp from Bevy

### Webhook Payload Examples

See Bevy's webhook documentation for complete payload structures. The plugin processes:

**Event webhook:**
```json
[{
  "type": "event",
  "data": [{
    "id": 123,
    "title": "Event Title",
    "status": "Published",
    "updated_ts": "2024-01-20T10:00:00Z",
    ...
  }]
}]
```

**Attendee webhook:**
```json
[{
  "type": "attendee",
  "data": [{
    "event_id": 123,
    "email": "user@example.com",
    "status": "registered",
    ...
  }]
}]
```

## License

MIT License - See LICENSE file for details

## Support

For issues and feature requests, please use the GitHub issue tracker.
