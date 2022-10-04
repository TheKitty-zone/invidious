# "Invidious" (which is an alternative front-end to YouTube)
# Copyright (C) 2019  Omar Roth
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require "digest/md5"
require "file_utils"

# Require kemal, kilt, then our own overrides
require "kemal"
require "kilt"
require "./ext/kemal_content_for.cr"
require "./ext/kemal_static_file_handler.cr"

require "athena-negotiation"
require "openssl/hmac"
require "option_parser"
require "sqlite3"
require "xml"
require "yaml"
require "compress/zip"
require "protodec/utils"

require "./invidious/database/*"
require "./invidious/database/migrations/*"
require "./invidious/helpers/*"
require "./invidious/yt_backend/*"
require "./invidious/frontend/*"

require "./invidious/*"
require "./invidious/channels/*"
require "./invidious/user/*"
require "./invidious/search/*"
require "./invidious/routes/**"
require "./invidious/jobs/**"

CONFIG   = Config.load
HMAC_KEY = CONFIG.hmac_key || Random::Secure.hex(32)

PG_DB       = DB.open CONFIG.database_url
ARCHIVE_URL = URI.parse("https://archive.org")
LOGIN_URL   = URI.parse("https://accounts.google.com")
PUBSUB_URL  = URI.parse("https://pubsubhubbub.appspot.com")
REDDIT_URL  = URI.parse("https://www.reddit.com")
YT_URL      = URI.parse("https://www.youtube.com")
HOST_URL    = make_host_url(Kemal.config)

CHARS_SAFE         = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
TEST_IDS           = {"AgbeGFYluEA", "BaW_jenozKc", "a9LDPn-MO4I", "ddFvjfvPnqk", "iqKdEhx-dD4"}
MAX_ITEMS_PER_PAGE = 1500

REQUEST_HEADERS_WHITELIST  = {"accept", "accept-encoding", "cache-control", "content-length", "if-none-match", "range"}
RESPONSE_HEADERS_BLACKLIST = {"access-control-allow-origin", "alt-svc", "server"}
HTTP_CHUNK_SIZE            = 10485760 # ~10MB

CURRENT_BRANCH  = {{ "#{`git branch | sed -n '/* /s///p'`.strip}" }}
CURRENT_COMMIT  = {{ "#{`git rev-list HEAD --max-count=1 --abbrev-commit`.strip}" }}
CURRENT_VERSION = {{ "#{`git log -1 --format=%ci | awk '{print $1}' | sed s/-/./g`.strip}" }}

# This is used to determine the `?v=` on the end of file URLs (for cache busting). We
# only need to expire modified assets, so we can use this to find the last commit that changes
# any assets
ASSET_COMMIT = {{ "#{`git rev-list HEAD --max-count=1 --abbrev-commit -- assets`.strip}" }}

SOFTWARE = {
  "name"    => "invidious",
  "version" => "#{CURRENT_VERSION}-#{CURRENT_COMMIT}",
  "branch"  => "#{CURRENT_BRANCH}",
}

YT_POOL = YoutubeConnectionPool.new(YT_URL, capacity: CONFIG.pool_size, use_quic: CONFIG.use_quic)

if CONFIG.output.upcase != "STDOUT"
  FileUtils.mkdir_p(File.dirname(CONFIG.output))
end
OUTPUT = CONFIG.output.upcase == "STDOUT" ? STDOUT : File.open(CONFIG.output, mode: "a")
LOGGER = Invidious::LogHandler.new(OUTPUT, CONFIG.log_level)

# Start jobs
DECRYPT_FUNCTION = DecryptFunction.new(CONFIG.decrypt_polling)
if CONFIG.decrypt_polling
  Invidious::Jobs.register Invidious::Jobs::UpdateDecryptFunctionJob.new
end

if CONFIG.popular_enabled
  Invidious::Jobs.register Invidious::Jobs::PullPopularVideosJob.new(PG_DB)
end

CONNECTION_CHANNEL = Channel({Bool, Channel(PQ::Notification)}).new(32)
Invidious::Jobs.register Invidious::Jobs::NotificationJob.new(CONNECTION_CHANNEL, CONFIG.database_url)

Invidious::Jobs.start_all

def popular_videos
  Invidious::Jobs::PullPopularVideosJob::POPULAR_VIDEOS.get
end

# Routing

before_all do |env|
  Invidious::Routes::BeforeAll.handle(env)
end

Invidious::Routing.register_all

error 404 do |env|
  Invidious::Routes::ErrorRoutes.error_404(env)
end

error 500 do |env, ex|
  error_template(500, ex)
end

static_headers do |response|
  response.headers.add("Cache-Control", "max-age=2629800")
end

# Init Kemal

public_folder "assets"

Kemal.config.powered_by_header = false
add_handler FilteredCompressHandler.new
add_handler APIHandler.new
add_handler AuthHandler.new
add_handler DenyFrame.new
add_context_storage_type(Array(String))
add_context_storage_type(Preferences)
add_context_storage_type(Invidious::User)

Kemal.config.logger = LOGGER
Kemal.config.host_binding = Kemal.config.host_binding != "0.0.0.0" ? Kemal.config.host_binding : CONFIG.host_binding
Kemal.config.port = Kemal.config.port != 3000 ? Kemal.config.port : CONFIG.port
Kemal.config.app_name = "Invidious"

# Use in kemal's production mode.
# Users can also set the KEMAL_ENV environmental variable for this to be set automatically.
{% if flag?(:release) || flag?(:production) %}
  Kemal.config.env = "production" if !ENV.has_key?("KEMAL_ENV")
{% end %}

Kemal.run
