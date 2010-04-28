require File.join(File.dirname(__FILE__), '../test_helper')

if defined? ActionController::Session::AbstractStore


SmartSessionStore.class_eval do
  attr_accessor :test_proc
  def get_fresh_session_with_test_support(*args)
    result = get_fresh_session_without_test_support(*args)
    if test_proc
      test_proc.call
    end
    result
  end
  
  alias_method_chain :get_fresh_session, :test_support
end

class SmartSessionTest < ActiveSupport::TestCase
  fixtures :sessions
  
  SessionKey = '_myapp_session'
  SessionSecret = 'b3c631c314c0bbca50c1b2843150fe33'

  SessionHash = ActionController::Session::AbstractStore::SessionHash
  SmartSessionStoreApp = SmartSessionStore.new(nil, :key => SessionKey, :secret => SessionSecret)

  #short circuit this so that the session id us our static one
  def SmartSessionStoreApp.load_session(env)
    sid, session = get_session(env, '123456')
    [sid, session]
  end
  # Replace this with your real tests.
  def setup
    @env = { ActionController::Session::AbstractStore::ENV_SESSION_KEY => '123456',  ActionController::Session::AbstractStore::ENV_SESSION_OPTIONS_KEY => ActionController::Session::AbstractStore::DEFAULT_OPTIONS}
    SmartSessionStore.session_class = TEST_SESSION_CLASS
    SmartSessionStoreApp.test_proc = nil
  end  
  

  def test_optimistic_locking_should_merge_if_row_data_has_not_changed_but_version_has
    with_locking do
      setup_base_session {|s| s[:name] = 'fred'}

      duped_env = @env.dup
      base_session = SessionHash.new(SmartSessionStoreApp, duped_env)
      base_session.send :load!
      base_session[:name] = 'bob'

      setup_base_session {|s| s[:name] = 'oldfred'}
      setup_base_session {|s| s[:name] = 'fred'}

      SmartSessionStoreApp.send :set_session, duped_env, '123456', base_session.to_hash
      assert_final_session :name => 'bob'
      SqlSession.delete_all
    end
  end

  def test_optimistic_locking_retries
    #see test_duplicate_on_first_insert for why we mess around with threads
    with_locking do
      main_test = Thread.new do
        setup_base_session {|s| s[:name] = 'fred'}
        duped_env = @env.dup
        session = SessionHash.new(SmartSessionStoreApp, duped_env)
        session.send :load!
        session[:user_id] = 123
      
        #we want this to happen inside a transaction other than the original (as it would happen in real life. this is a bit of a hack), so we use a separate thread
        t = Thread.new do
          setup_base_session {|s| s[:age] = 21}
        end
        t.join
        SmartSessionStoreApp.send :set_session, duped_env, '123456', session.to_hash
        assert_final_session :age => 21 , :name => 'fred', :user_id => 123
        SqlSession.delete_all
        
      end
      main_test.join
    end
  end
  
  #These databases handle the uniquequess contrain differently
  #
  def test_duplicate_on_first_insert_with_locking
    with_locking do
      duped_env = @env.dup
      base_session = SessionHash.new(SmartSessionStoreApp, duped_env)
      base_session.send :load!

      setup_base_session {|s| s[:name] = 'fred'}

      base_session[:foo] = 'bar'
      SmartSessionStoreApp.send :set_session, duped_env, '123456', base_session.to_hash

      assert_final_session :foo => 'bar', :name => 'fred'

    end
  end

  if ENV['DATABASE'] != 'sqlite3' #throws SQLite3::BusyException: database is locked because of sqlite3's concurrency
    def test_duplicate_on_first_insert
  #craziness with threads is to escape the transaction created for us. This 
  #does mean that if this test screws up cruft will be left in the sessions table
      main_test = Thread.new do
        duped_env = @env.dup
        base_session = SessionHash.new(SmartSessionStoreApp, duped_env)
        base_session.send :load!

        SmartSessionStoreApp.test_proc = lambda do 

          #we want this to happen inside a transaction other than the original (as it would happen in real life. this is a bit of a hack), so we use a separate thread
          t = Thread.new do
            SmartSessionStoreApp.test_proc = nil
            another_env = @env.dup 
  
            other_session = SessionHash.new(SmartSessionStoreApp, another_env)
            other_session.send :load!
            other_session[:name] = 'fred'
    
            SmartSessionStoreApp.send :set_session, another_env, '123456', other_session.to_hash
          end
          t.join
        end
        base_session[:foo] = 'bar'
        SmartSessionStoreApp.send :set_session, duped_env, '123456', base_session.to_hash

        assert_final_session :foo => 'bar', :name => 'fred'
        SqlSession.delete_all #because we mess with transactions
      end
      main_test.join
    end
  end
  
  def test_simultaneous_access_session_not_created_with_locking
    with_locking do
      test_simultaneous_access_session_not_created
    end
  end
  
  def test_optimisic_locking_not_used_for_first_save
    with_locking do
      base_session = SessionHash.new(SmartSessionStoreApp, @env)
      base_session.send :load!
  
      assert_equal 0, @env[SmartSessionStore::SESSION_RECORD_KEY].lock_version
      TEST_SESSION_CLASS.expects(:update_session_optimistically).never
      SmartSessionStoreApp.send :set_session, @env, '123456', base_session.to_hash
    end
  end
  
  def test_optimisic_locking_counter_incremented
    with_locking do
      duped_env = @env.dup
      base_session = SessionHash.new(SmartSessionStoreApp, duped_env)
      base_session.send :load!
      base_session[:last_viewed_page] = 'woof'
  
      SmartSessionStoreApp.send :set_session, duped_env, '123456', base_session.to_hash
      assert_equal 0, duped_env[SmartSessionStore::SESSION_RECORD_KEY].lock_version
      base_session[:last_viewed_page] = 'home'
      SmartSessionStoreApp.send :set_session, duped_env, '123456', base_session.to_hash
  
      
      session_record = TEST_SESSION_CLASS.find_session '123456'
      assert_equal 1, session_record.lock_version
      assert_equal 1, duped_env[SmartSessionStore::SESSION_RECORD_KEY].lock_version
    
      SqlSession.connection.execute 'update sessions set lock_version = lock_version + 1'
  
      base_session[:last_viewed_page] = 'news'
      SmartSessionStoreApp.send :set_session, duped_env, '123456', base_session.to_hash
  
      session_record = TEST_SESSION_CLASS.find_session '123456'
      assert_equal 3, session_record.lock_version
      assert_equal 3, duped_env[SmartSessionStore::SESSION_RECORD_KEY].lock_version
  
      assert_final_session :last_viewed_page => 'news'
  
      duped_env = @env.dup
      base_session = SessionHash.new(SmartSessionStoreApp, duped_env)
      base_session.send :load!
      assert_equal 3, duped_env[SmartSessionStore::SESSION_RECORD_KEY].lock_version
    end
  end  
  
  def test_simultaneous_access_session_already_created
    setup_base_session do |base_session|
      base_session[:last_viewed_page] = 'home'
    end
        
    do_simultaneous_session_access do |first_data, second_data|
      first_data[:user_id] = 123
      first_data[:last_viewed_page] = 'news'
      second_data[:favourite_food] = 'pizza'
    end
    
    assert_final_session :user_id => 123, :favourite_food => 'pizza', :last_viewed_page => 'news'
  end
  
  def test_simultaneous_access_session_already_created_with_locking
    with_locking do
      test_simultaneous_access_session_already_created
    end
  end
  
  def test_simultaneous_access_session_not_created
    do_simultaneous_session_access do |first_data, second_data|
      first_data[:user_id] = 123
      second_data[:favourite_food] = 'pizza'
    end
    
    assert_final_session :user_id => 123, :favourite_food => 'pizza'
  end
  

  def test_simultaneous_access_delete_keys
    
    setup_base_session do |base_session|
      base_session[:key_to_delete] = 123
      base_session[:key_to_preserve] = 456
    end
    
    do_simultaneous_session_access do |first_data, second_data|
      first_data[:user_id] = 789      
      first_data.delete :key_to_delete
      first_data[:key_to_preserve] = 123
      second_data[:favourite_food] = 'pizza'
    end
    
    assert_final_session :key_to_preserve => 123, :favourite_food => 'pizza', :user_id => 789
  end
  
  def test_simultaneous_access_delete_keys_with_locking
    with_locking do
      test_simultaneous_access_delete_keys
    end
  end
  
  def test_deep_session_object
    setup_base_session do |base_session|
      base_session[:flash] = {:notice => 'Please login'}
    end
    
    setup_base_session do |base_session|
      base_session[:flash][:notice] = 'Thanks for logging in'
    end
    assert_final_session( :flash => {:notice => 'Thanks for logging in'})
  end
  
  class ClassWithOddEqual < Hash
    attr_accessor :ivar
  end
  
  def test_objects_with_odd_equal
    w = ClassWithOddEqual.new
    w[:name] = 'paul'
    
    setup_base_session do |base_session|
      base_session[:flash] = w
    end
    
    w.ivar = 123
    
    setup_base_session do |base_session|
      base_session[:flash] = w
    end
    
    setup_base_session do |base_session|
      assert_equal base_session[:flash].ivar, 123
    end
    
  end
  
  private
  
  def assert_final_session expected
    consolidated_session = SessionHash.new(SmartSessionStoreApp, @env.dup)
    consolidated_session.send :load!
    assert_equal expected, consolidated_session.to_hash
  end
  
  def setup_base_session
    duped_env = @env.dup
    base_session = SessionHash.new(SmartSessionStoreApp, duped_env)
    base_session.send :load!
    yield base_session if block_given?
    SmartSessionStoreApp.send :set_session, duped_env, '123456', base_session.to_hash
  end
  
  def do_simultaneous_session_access
    first_env = @env.dup
    second_env = @env.dup
    first_session = SessionHash.new(SmartSessionStoreApp, first_env)
    second_session = SessionHash.new(SmartSessionStoreApp, second_env)
        
    yield first_session, second_session
    SmartSessionStoreApp.send :set_session, first_env, '123456', first_session.to_hash
    SmartSessionStoreApp.send :set_session, second_env, '123456', second_session.to_hash
    
  end
end


ActionController::Base.session_store = nil
class FullStackTest < ActionController::IntegrationTest
  fixtures :sessions
  
  DispatcherApp = ActionController::Dispatcher.new
  SessionApp = SmartSessionStore.new(DispatcherApp,   :key => '_session_id')

  def setup
    @integration_session = open_session(SessionApp)
  end
    
  class TestController < ActionController::Base

    def set_session_value
      session[:foo] = params[:foo] || "bar"
      head :ok
    end

    def get_session_value
      render :text => "foo: #{session[:foo].inspect}"
    end

    def get_session_id
      session[:foo]
      render :text => "#{request.session_options[:id]}"
    end

    def call_reset_session
      session[:foo]
      reset_session
      session[:foo] = "baz"
      head :ok
    end

    def rescue_action(e) raise end
  end
  
  def test_setting_and_getting_session_value
    with_test_route_set do
      get '/set_session_value'
      assert_response :success
      assert cookies['_session_id']

      get '/get_session_value'
      assert_response :success
      assert_equal 'foo: "bar"', response.body

      get '/set_session_value', :foo => "baz"
      assert_response :success
      assert cookies['_session_id']

      get '/get_session_value'
      assert_response :success
      assert_equal 'foo: "baz"', response.body
    end
  end
  
  def test_setting_and_getting_session_value_with_locking
    with_locking do
      test_setting_and_getting_session_value
    end
  end

  def test_getting_nil_session_value
    with_test_route_set do
      get '/get_session_value'
      assert_response :success
      assert_equal 'foo: nil', response.body
    end
  end

  def test_setting_session_value_after_session_reset
    with_test_route_set do
      get '/set_session_value'
      assert_response :success
      assert cookies['_session_id']
      session_id = cookies['_session_id']

      get '/call_reset_session'
      assert_response :success
      assert_not_equal [], headers['Set-Cookie']

      get '/get_session_value'
      assert_response :success
      assert_equal 'foo: "baz"', response.body

      get '/get_session_id'
      assert_response :success
      assert_not_equal session_id, response.body
    end
  end

  def test_setting_session_value_after_session_reset_with_locking
    with_locking do
      test_setting_session_value_after_session_reset
    end
  end

  def test_getting_session_id
    with_test_route_set do
      get '/set_session_value'
      assert_response :success
      assert cookies['_session_id']
      session_id = cookies['_session_id']

      get '/get_session_id'
      assert_response :success
      assert_equal session_id, response.body
    end
  end

  def test_getting_session_id_with_locking
    with_locking do
      test_getting_session_id
    end
  end



  private
    def with_test_route_set
      with_routing do |set|
        set.draw do |map|
          map.with_options :controller => "full_stack_test/test" do |c|
            c.connect "/:action"
          end
        end
        yield
      end
    end
  
end



end
