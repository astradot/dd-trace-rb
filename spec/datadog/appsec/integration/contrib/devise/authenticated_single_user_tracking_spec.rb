# frozen_string_literal: true

require 'datadog/tracing/contrib/support/spec_helper'
require 'datadog/appsec/spec_helper'
require 'rack/test'

require 'action_controller/railtie'
require 'active_record'
require 'sqlite3'
require 'devise'

RSpec.describe 'Devise auto authenticated sing-user tracking' do
  include Rack::Test::Methods
  include Warden::Test::Helpers

  before do
    # NOTE: By doing this we are emulating the initial load of the devise rails
    #       engine for every test case. It will install the required middleware.
    #       WARNING: This is a hack!
    Devise.send(:remove_const, :Engine)
    load File.join(Gem.loaded_specs['devise'].full_gem_path, 'lib/devise/rails.rb')

    Devise.setup do |config|
      config.secret_key = 'test-secret-key'

      require 'devise/orm/active_record'

      config.sign_out_via = :delete
      config.responder.error_status = :unprocessable_entity
      config.responder.redirect_status = :see_other
      config.sign_out_all_scopes = false
      config.parent_controller = 'TestApplicationController'
      config.paranoid = true
      config.stretches = 1
      config.password_length = 6..8
      config.http_authenticatable = true
    end

    # app/models
    stub_const('User', Class.new(ActiveRecord::Base)).tap do |klass|
      klass.establish_connection({adapter: 'sqlite3', database: ':memory:'})
      klass.connection.create_table 'users', force: :cascade do |t|
        t.string :username, null: false
        t.string :email, default: '', null: false
        t.string :encrypted_password, default: '', null: false
      end

      klass.class_eval do
        devise :database_authenticatable, :registerable, :validatable
      end

      # prevent internal sql requests from showing up
      klass.count
    end

    stub_const('TestApplicationController', Class.new(ActionController::Base)).class_eval do
      before_action :configure_permitted_parameters, if: :devise_controller?

      def configure_permitted_parameters
        devise_parameter_sanitizer.permit(:sign_up) do |user|
          user.permit(:username, :email, :password, :password_confirmation)
        end
      end
    end

    # NOTE: Unfortunately, can't figure out why devise receives 3 times `finalize!`
    #       of the RouteSet patch, hence it's bypassed with below hack.
    #       The order of hacks matters!
    allow(Devise).to receive(:regenerate_helpers!)

    # Rails app
    # NOTE: https://github.com/heartcombo/devise/blob/fec67f98f26fcd9a79072e4581b1bd40d0c7fa1d/guides/bug_report_templates/integration_test.rb#L43-L57
    app = Class.new(Rails::Application) do
      config.root = __dir__
      config.secret_key_base = 'test-secret-key-base'
      config.action_dispatch.show_exceptions = :rescuable
      config.hosts.clear
      config.eager_load = false
      config.consider_all_requests_local = true
      # NOTE: For debugging replace with $stdout
      config.logger = Rails.logger = Logger.new(StringIO.new)

      config.file_watcher = Class.new(ActiveSupport::FileUpdateChecker) do
        def initialize(files, dirs = {}, &block)
          dirs = dirs.delete('') if dirs.include?('')

          super
        end
      end
    end

    stub_const('RailsTest::Application', app)

    Datadog.configure do |config|
      config.tracing.enabled = true
      config.tracing.instrument :rails
      config.tracing.instrument :http

      config.appsec.enabled = true
      config.appsec.instrument :rails
      config.appsec.instrument :devise
      config.appsec.auto_user_instrumentation.mode = 'identification'

      config.remote.enabled = false
    end

    app.initialize!
    app.routes.draw do
      devise_for :users, controllers: {registrations: 'test_registrations'}

      get '/public' => 'public#index'
      get '/private' => 'private#index'
    end

    # NOTE: Unfortunately, can't figure out why devise receives 3 times `finalize!`
    #       of the RouteSet patch, hence it's bypassed with below hack.
    #       The order of hacks matters!
    Devise.class_variable_set(:@@warden_configured, nil) # rubocop:disable Style/ClassVars
    Devise.configure_warden!

    # app/controllers
    public_controller
    stub_const('PrivateController', Class.new(ActionController::Base)).class_eval do
      before_action :authenticate_user!

      def index
        respond_to do |format|
          format.html { render plain: 'This is private page' }
        end
      end
    end

    allow(Rails).to receive(:application).and_return(app)

    # NOTE: Don't reach the agent in any way
    allow_any_instance_of(Datadog::Tracing::Transport::HTTP::Client).to receive(:send_request)
    allow_any_instance_of(Datadog::Tracing::Transport::Traces::Transport).to receive(:native_events_supported?)
      .and_return(true)
  end

  after do
    clear_traces!

    Datadog.configuration.reset!
    Datadog.registry[:rack].reset_configuration!

    ActiveSupport::Dependencies.clear if Rails.application
    ActiveSupport::Dependencies.autoload_paths = []
    ActiveSupport::Dependencies.autoload_once_paths = []
    ActiveSupport::Dependencies._eager_load_paths = Set.new
    ActiveSupport::Dependencies._autoloaded_tracked_classes = Set.new

    # rubocop:disable Style/ClassVars
    Rails::Railtie::Configuration.class_variable_set(:@@eager_load_namespaces, nil)
    Rails::Railtie::Configuration.class_variable_set(:@@watchable_files, nil)
    Rails::Railtie::Configuration.class_variable_set(:@@watchable_dirs, nil)
    Rails::Railtie::Configuration.class_variable_set(:@@app_generators, nil)
    Rails::Railtie::Configuration.class_variable_set(:@@to_prepare_blocks, nil)
    Rails::Railtie::Configuration.class_variable_set(:@@app_middleware, nil)
    Devise.class_variable_set(:@@mappings, {})
    Devise.class_variable_set(:@@warden_configured, nil)
    # rubocop:enable Style/ClassVars

    # Remnove Rails caches
    Rails.app_class = nil
    Rails.cache = nil
  end

  let(:public_controller) do
    stub_const('PublicController', Class.new(ActionController::Base)).class_eval do
      def index
        respond_to do |format|
          format.html { render plain: 'This is public page' }
        end
      end
    end
  end

  let(:http_service_entry_span) { spans.find { |s| s.name == 'rack.request' } }
  let(:http_service_entry_trace) { traces.find { |t| t.id == http_service_entry_span.trace_id } }

  let(:response) { last_response }
  let(:app) { Rails.application }

  context 'when user is not authenticated' do
    it 'allows unauthenticated user to visit public page and does not track it' do
      get('/public')

      expect(response).to be_ok
      expect(response.body).to eq('This is public page')

      expect(http_service_entry_span.tags).not_to have_key('usr.id')
      expect(http_service_entry_span.tags).not_to have_key('appsec.events.users.login.success.track')
      expect(http_service_entry_span.tags).not_to have_key('appsec.events.users.login.failure.track')
      expect(http_service_entry_span.tags).not_to have_key('_dd.appsec.usr.id')
    end

    it 'forbids unauthenticated user to visit private page and does not track it' do
      get('/private')

      expect(response).to be_redirect
      expect(response.location).to match('users/sign_in')

      expect(http_service_entry_span.tags).not_to have_key('usr.id')
      expect(http_service_entry_span.tags).not_to have_key('appsec.events.users.login.success.track')
      expect(http_service_entry_span.tags).not_to have_key('appsec.events.users.login.failure.track')
      expect(http_service_entry_span.tags).not_to have_key('_dd.appsec.usr.id')
    end
  end

  context 'when user is authenticated' do
    before do
      user = User.create!(username: 'JohnDoe', email: 'john.doe@example.com', password: '123456')
      login_as(user)
    end

    it 'allows authenticated user to visit public page and tracks it' do
      get('/public')

      expect(response).to be_ok
      expect(response.body).to eq('This is public page')

      expect(http_service_entry_span.tags).to include(
        'usr.id' => '1',
        '_dd.appsec.usr.id' => '1',
        '_dd.appsec.user.collection_mode' => 'identification'
      )
    end

    it 'allows authenticated user to visit private page and tracks it' do
      get('/private')

      expect(response).to be_ok
      expect(response.body).to eq('This is private page')

      expect(http_service_entry_span.tags).to include(
        'usr.id' => '1',
        '_dd.appsec.usr.id' => '1',
        '_dd.appsec.user.collection_mode' => 'identification'
      )
    end
  end

  context 'when user is authenticated and mode is anonymization' do
    before do
      allow(Datadog::AppSec::Contrib::Devise::Configuration).to receive(:auto_user_instrumentation_mode)
        .and_return('anonymization')

      user = User.create!(username: 'JohnDoe', email: 'john.doe@example.com', password: '123456')
      login_as(user)
    end

    it 'allows authenticated user to visit public page and tracks it with anonymized user id' do
      get('/public')

      expect(response).to be_ok
      expect(response.body).to eq('This is public page')

      expect(http_service_entry_span.tags).to include(
        'usr.id' => match(%r{anon_[a-z0-9]{32}}),
        '_dd.appsec.usr.id' => match(%r{anon_[a-z0-9]{32}}),
        '_dd.appsec.user.collection_mode' => 'anonymization'
      )
    end
  end

  context 'when user is authenticated and customer already uses SDK to set user' do
    before do
      user = User.create!(username: 'JohnDoe', email: 'john.doe@example.com', password: '123456')
      login_as(user)
    end

    let(:public_controller) do
      stub_const('PublicController', Class.new(ActionController::Base)).class_eval do
        def index
          span = Datadog::Tracing.active_span
          trace = Datadog::Tracing.active_trace

          Datadog::Kit::Identity.set_user(trace, span, id: '42', email: 'hello@gmail.com')

          respond_to do |format|
            format.html { render plain: 'This is public page' }
          end
        end
      end
    end

    it 'allows authenticated user to visit public page and tracks it with SDK values' do
      get('/public')

      expect(response).to be_ok
      expect(response.body).to eq('This is public page')

      expect(http_service_entry_span.tags).to include(
        'usr.id' => '42',
        'usr.email' => 'hello@gmail.com',
        '_dd.appsec.usr.id' => '1',
        '_dd.appsec.user.collection_mode' => 'sdk'
      )
    end
  end
end
