require 'spec_helper'
require 'td/command/common'
require 'td/updater'
require 'webrick'
require 'webrick/https'
require 'webrick/httpproxy'
require 'logger'

module TreasureData::Updater

  describe 'without the TD_TOOLBELT_UPDATE_ROOT environment variable defined' do
    let :default_toolbelt_url do
      "http://toolbelt.treasuredata.com"
    end

    describe 'endpoints methods' do
      it 'use the default root path' do
        TreasureData::Updater.endpoint_root.should == default_toolbelt_url
        TreasureData::Updater.version_endpoint.should =~ Regexp.new(default_toolbelt_url)
        TreasureData::Updater.update_package_endpoint.should =~ Regexp.new(default_toolbelt_url)
      end
    end
  end

  describe 'with the TD_TOOLBELT_UPDATE_ROOT environment variable defined' do
    before do
      ENV['TD_TOOLBELT_UPDATE_ROOT'] = 'https://0.0.0.0:5000/'
    end
    describe 'endpoints methods' do
      it 'use the custom root path' do
        TreasureData::Updater.endpoint_root.should == ENV['TD_TOOLBELT_UPDATE_ROOT']
        TreasureData::Updater.version_endpoint.should =~ Regexp.new(ENV['TD_TOOLBELT_UPDATE_ROOT'])
        TreasureData::Updater.update_package_endpoint.should =~ Regexp.new(ENV['TD_TOOLBELT_UPDATE_ROOT'])
      end
    end
    after do
      ENV.delete 'TD_TOOLBELT_UPDATE_ROOT'
    end
  end

  describe 'with a proxy' do
    before :each do
      setup_proxy_server
      setup_server
    end

    after :each do
      if @proxy_server
        @proxy_server.shutdown
        @proxy_server_thread.join
      end
      if @server
        @server.shutdown
        @server_thread.join
      end
    end

    class TestUpdater
      include TreasureData::Updater::ModuleDefinition

      def initialize(endpoint_root)
        @endpoint_root = endpoint_root
      end

      def updating_lock_path
        File.expand_path("updating_lock_path.lock", File.dirname(__FILE__))
      end

      def on_windows?
        true
      end

      def endpoint_root
        @endpoint_root
      end

      def latest_local_version
        '0.11.5'
      end
    end

    class JarUpdateTester
      include TreasureData::Updater

      def kick
        jar_update
      end
    end

    it 'downloads tmp.zip via proxy and raise td version conflict' do
      with_proxy do
        expect {
          TestUpdater.new("https://localhost:#{@server.config[:Port]}").update
        }.to raise_error TreasureData::Command::UpdateError
      end
    end

    it 'works' do
      with_proxy do
        with_env('TD_TOOLBELT_JARUPDATE_ROOT', "https://localhost:#{@server.config[:Port]}") do
          expect {
            JarUpdateTester.new.kick
          }.not_to raise_error
        end
      end
    end

    def with_proxy
      with_env('HTTP_PROXY', "http://localhost:#{@proxy_server.config[:Port]}") do
        yield
      end
    end

    def with_env(name, var)
      backup, ENV[name] = ENV[name], var
      begin
        yield
      ensure
        ENV[name] = backup
      end
    end

    def setup_proxy_server
      logger = Logger.new(STDERR)
      logger.progname = 'proxy'
      logger.level = Logger::Severity::FATAL  # avoid logging
      @proxy_server = WEBrick::HTTPProxyServer.new(
        :BindAddress => "localhost",
        :Logger => logger,
        :Port => 0,
        :AccessLog => []
      )
      @proxy_server_thread = start_server_thread(@proxy_server)
      @proxy_server
    end

    def setup_server
      logger = Logger.new(STDERR)
      logger.progname = 'server'
      logger.level = Logger::Severity::FATAL  # avoid logging
      @server = WEBrick::HTTPServer.new(
        :BindAddress => "localhost",
        :Logger => logger,
        :Port => 0,
        :AccessLog => [],
        :DocumentRoot => '.',
        :SSLEnable => true,
        :SSLCACertificateFile => fixture_file('ca.cert'),
        :SSLCertificate => cert('server.cert'),
        :SSLPrivateKey => key('server.key')
      )
      @serverport = @server.config[:Port]
      @server.mount(
        '/version.exe',
        WEBrick::HTTPServlet::ProcHandler.new(method(:version).to_proc)
      )
      @server.mount(
        '/td-update-exe.zip',
        WEBrick::HTTPServlet::ProcHandler.new(method(:download).to_proc)
      )
      @server.mount(
        '/maven2/com/treasuredata/td-import/maven-metadata.xml',
        WEBrick::HTTPServlet::ProcHandler.new(method(:metadata).to_proc)
      )
      @server_thread = start_server_thread(@server)
      @server
    end

    def version(req, res)
      res['content-type'] = 'text/plain'
      res.body = '0.11.6'
    end

    def download(req, res)
      res['content-type'] = 'application/octet-stream'
      res.body = File.read(fixture_file('tmp.zip'))
    end

    def metadata(req, res)
      res['content-type'] = 'application/xml'
      res.body = '<metadata><versioning><lastUpdated>20141204123456</lastUpdated><release>version</release></versioning></metadata>'
    end

    def start_server_thread(server)
      t = Thread.new {
        Thread.current.abort_on_exception = true
        server.start
      }
      while server.status != :Running
        sleep 0.1
        unless t.alive?
          t.join
          raise
        end
      end
      t
    end

    def cert(filename)
      OpenSSL::X509::Certificate.new(File.read(fixture_file(filename)))
    end

    def key(filename)
      OpenSSL::PKey::RSA.new(File.read(fixture_file(filename)))
    end

    def fixture_file(filename)
      File.expand_path(File.join('fixture', filename), File.dirname(__FILE__))
    end
  end
end
