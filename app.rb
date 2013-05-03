require "sinatra"
require "google/api_client"
require "data_mapper"
require "twilio-ruby"
require 'rack-ssl-enforcer'
DataMapper::setup(:default, ENV["DB_URL"] || "sqlite3://#{Dir.pwd}/dev.db")

set :sessions, true

class TokenPair
  include DataMapper::Resource

  property :id, Serial
  property :refresh_token, String, :length => 255
  property :access_token, String, :length => 255
  property :expires_in, Integer
  property :issued_at, Integer
  property :phone_number, String, :length => 20

  def update_token!(object)
    self.refresh_token = object.refresh_token
    self.access_token = object.access_token
    self.expires_in = object.expires_in
    self.issued_at = object.issued_at
  end

  def to_hash
    return {
      :refresh_token => refresh_token,
      :access_token => access_token,
      :expires_in => expires_in,
      :issued_at => Time.at(issued_at)
    }
  end
end
DataMapper.finalize
DataMapper.auto_upgrade!
use Rack::SslEnforcer
before do
  @base_url = "https://myserver.com"
  @twilio = Twilio::REST::Client.new "ACxxxxxxxxxxxxxxxxxxxxxxxx", "yyyyyyyyyyyyyyyyyyyyyyyyy"
  @client = Google::APIClient.new
  @client.authorization.client_id = "1234.apps.googleusercontent.com"
  @client.authorization.client_secret = "ITSASECRET"
  @client.authorization.scope = [
    "https://www.googleapis.com/auth/glass.timeline",
    "https://www.googleapis.com/auth/userinfo.profile"
  ]
  @client.authorization.redirect_uri = to("/oauth2callback")
  @client.authorization.code = params[:code] if params[:code]
  @glass = @client.discovered_api( "mirror", "v1" )
  @oauth2 = @client.discovered_api( "oauth2", "v2" )

  if request.path_info == '/subcallback' #if we get a push from google, do a different lookup based on the userToken
    @data = JSON.parse(request.body.read)
    token_pair = TokenPair.get(@data['userToken'])
    @phone_number = token_pair.phone_number
    @client.authorization.update_token!(token_pair.to_hash)
  else
    if session[:token_id] #if the user is logged in
      token_pair = TokenPair.get(session[:token_id])
      @client.authorization.update_token!(token_pair.to_hash)
      @phone_number = token_pair.phone_number
    else #if we are receiving an SMS
      token_pair = TokenPair.first(:phone_number => params[:To])
      if !token_pair.nil?
        @client.authorization.update_token!(token_pair.to_hash)
      end
    end
  end
  if @client.authorization.refresh_token && @client.authorization.expired?
    @client.authorization.fetch_access_token!
  end

  #redirect the user to OAuth if we're logged out
  unless @client.authorization.access_token || request.path_info =~ /^\/oauth2/
    redirect to("/oauth2authorize")
  end
end

get "/oauth2authorize" do
  redirect @client.authorization.authorization_uri.to_s, 303
end

get "/oauth2callback" do
  @client.authorization.fetch_access_token!
  token_pair = if session[:token_id]
    TokenPair.get(session[:token_id])
  else
    TokenPair.new
  end
  token_pair.update_token!(@client.authorization)
  numbers = @twilio.account.available_phone_numbers.get('US').local.list

  @twilio.account.incoming_phone_numbers.create(:phone_number => numbers[0].phone_number, :sms_url => "#{@base_url}/receivesms")
  token_pair.phone_number = numbers[0].phone_number
  token_pair.save
  session[:token_id] = token_pair.id
  subscription = @glass.subscriptions.insert.request_schema.new({
    "collection" => "timeline",
    "userToken" => token_pair.id,
    "verifyToken" => "monkey",
    "callbackUrl" => "#{@base_url}/subcallback",
    "operation" => ["INSERT"]})
  result = @client.execute(
    :api_method => @glass.subscriptions.insert,
    :body_object => subscription)
  redirect to("/")
end
post "/receivesms" do
  timeline_item = @glass.timeline.insert.request_schema.new({
    :sourceItemId => params[:SmsSid],
    :menuItems => [{:action => "REPLY"}, {:action => "READ_ALOUD"}],
    :html => "<article>\n  <section>\n    <div class=\"text-auto-size\" style=\"\">\n      <p class=\"yellow\">SMS from #{params[:From]}</p>\n      <p>#{params[:Body]}</p>\n    </div>\n  </section>\n  <footer>\n    <div><img src=\"http://i.imgur.com/VM8Jji2.png\"></div>\n  </footer>\n</article>",
    :speakableText => params[:Body],
    :title => "SMS from #{params[:From]}",
    :notification => {:level => "AUDIO_ONLY"}})
  result = @client.execute(
      :api_method => @glass.timeline.insert,
      :body_object => timeline_item)
  twiml = Twilio::TwiML::Response.new 
  twiml.text
end
post "/subcallback" do
    reply_result = @client.execute(
      :api_method => @glass.timeline.get,
      :parameters => {"id" => @data["itemId"]},
      :authorization => @client.authorization)
    reply = reply_result.data.text
    msg_result = @client.execute(
      :api_method => @glass.timeline.get,
      :parameters => {"id" => reply_result.data.inReplyTo},
      :authorization => @client.authorization)
    smsSid = msg_result.data.sourceItemId
    sms = @twilio.account.sms.messages.get(smsSid)
    @twilio.account.sms.messages.create(:from => @phone_number, :to => sms.from, :body => reply)
end

get "/" do
    api_result = @client.execute(
      :api_method => @oauth2.userinfo.get)
    "You have authenticated as G+ user #{api_result.data.name}, your new Twilio-powered Glass phone number is #{@phone_number}<br><a href='http://www.twilio.com/' style='text: decoration: none; display: inline-block; width: 166px; height: 0; overflow: hidden; padding-top: 31px; background: url(http://www.twilio.com/packages/company/img/logos_icon_poweredbysmall.png) no-repeat;'>powered by twilio</a><br><br>Built by <a href='http://twitter.com/jomarkgo'>@jonmarkgo</a>"
end
