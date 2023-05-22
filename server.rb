require 'sinatra'

class Server < Sinatra::Application
  # TODO: check with JW if this can be removed - are we using api keys
  # everywhere now?
  ALLOWED_ACCESS_IP = %w[99.80.183.117 99.81.135.32 95.90.237.179]

  # Extremely sophisticated access management
  before do
    # don't limit endpoints unless they are on production
    return unless ENV['RACK_ENV'] == 'production'
requesting_ip = request.env["HTTP_X_FORWARDED_FOR"] || request.env['REMOTE_ADDR']
    api_key = fetch_valid_api_key(request.env, requesting_ip)
    return if api_key

    # handle IP based blocking
    unless ALLOWED_ACCESS_IP.include?(requesting_ip)
      failure(403, "I'm afraid I can't let you do that, #{requesting_ip}")
    end
  end

  # Notify on all errors
  error Exception do
    notify_telegram(:error, env['sinatra.error'].inspect)

    { msg: 'Something went wrong' }.to_json
  end

  get '/' do
    { msg: 'Please contact an admin to use the api' }.to_json
  end

  get '/global/daily' do
    Serializers::Global::DailyStats.serialize.to_json
  end

  get '/global/parcels' do
    Serializers::Global::Parcels.serialize.to_json
  end

  get '/global/scenes' do
    Serializers::Global::Scenes.serialize.to_json
  end

  get '/global/users' do
    Serializers::Global::Users.serialize.to_json
  end

  get '/rentals/summary' do
    dcl_property_rentals_api('/dcl_rentals/summary')
  end

  get '/rentals/closed' do
    dcl_property_rentals_api('/dcl_rentals/closed', params)
  end

  get '/scenes/top' do
    scenes = Models::DailySceneStats.
      basic_data.
      where(date: params[:date] || Date.today - 1).
      order(:unique_addresses).
      last(50)

    Serializers::Scenes.serialize(scenes, basic_data_only: true).to_json
  end

  # TODO: select the first date when there are multiple results (so lose distinct)
  # if the first result for first_seen_at is nil, find the first daily_scene model?
  get '/scenes/search' do
    query = "select distinct on (name)
              coordinates,
              first_seen_at,
              name,
              scene_disambiguation_uuid as uuid
            from scenes"

    # NOTE: for some reason there is different behavior between dev environments
    # and prod when using "Sequel.like" - in dev environments (and on prod
    # console...wtf) the query is formatted as SQL as expected. based on logs,
    # in prod this is *not* happening, and instead it renders a
    # "QualifiedIdentifier" class
    #
    # example:
    #
    # dev: WHERE (\"coordinates\" LIKE '%-70,-124%')">
    # prod: WHERE (\"coordinates\" LIKE '%#<Sequel::SQL::QualifiedIdentifier:0x..>%')"
    #
    # calling #qualify on the resulting dataset doesn't make a difference, so
    # for now will just write the sql directly

      case
      when params['coordinates'] && params['name']
        query += " where coordinates LIKE '%#{params['coordinates']}%' and name LIKE '%#{params['name']}%'"
      when params['coordinates']
        query += " where coordinates LIKE '%#{params['coordinates']}%'"
      when params['name']
        query += " where name LIKE '%#{params['name']}%'"
      end

    DATABASE_CONNECTION[query].first(10).to_json
  end

  get '/scenes/:uuid' do
    basic_data_only = params[:basic_data_only] || false
    data = basic_data_only ? Models::DailySceneStats.basic_data : Models::DailySceneStats

    stats = data.where(scene_disambiguation_uuid: params[:uuid])
    failure(404, "Can't find scene with uuid #{params[:uuid]}") if stats.nil?

    # return stats for the given date or the most recent daily stats available
    stats = params[:date] ? stats.first(date: params[:date]) : stats.order(:date).last
    failure(404, "Can't find scene with uuid #{params[:uuid]}") if stats.nil?

    Serializers::Scenes.serialize([stats], basic_data_only: basic_data_only).first.to_json
  end

  get '/scenes/:uuid/history' do
    offset = params[:offset] || 0
    limit = params[:limit] || 30
    failure(400, "Max limit is 30 days") if limit > 30

    basic_data_only = params[:basic_data_only] || false
    data = basic_data_only ? Models::DailySceneStats.basic_data : Models::DailySceneStats
    stats = data.
      where(scene_disambiguation_uuid: params[:uuid]).
      order(:date)
    failure(404, "Can't find scene with uuid #{params[:uuid]}") if stats.empty?

    serialized = Serializers::Scenes.serialize(
      stats.limit(limit).offset(offset).all,
      basic_data_only: basic_data_only
    )

    {
      total: stats.count,
      data: serialized
    }.to_json
  end

  get '/scenes/:uuid/visitor_history' do
    DATABASE_CONNECTION[
      "select date, unique_visitors as visitors
      from daily_scene_stats
      where scene_disambiguation_uuid = '#{params[:uuid]}'
      order by date desc
      limit 90"
    ].all.reverse.to_json
  end

  get '/parcels/all' do
    # TODO:
    # for individual parcels (different endpoint)
    # coordinates = params['coordinates']
    # parcels = Models::DailyParcelStats.yesterday.where(coordinates: coordinates)
    # result = Serializers::Parcels.serialize(parcels)

    date = params[:date] || Date.today - 1
    Models::SerializedDailyParcelStats.find(date: date)&.data_json
  end

  get '/users/:address' do
    user = Models::User.find(address: params[:address].downcase)
    failure(404, "Can't find user with address #{params[:address]}") if user.nil?

    {
      address: params[:address],
      name: user.name,
      avatar_url: user.avatar_url,
      first_seen: user.first_seen.to_s,
      last_seen: user.last_seen.to_s,
      guest: user.guest?,
      verified: user.verified?,
      dao_member: user.dao_member?
    }.to_json
  end

  get '/users/:address/activity/top_scenes' do
    user = Models::User.find(address: params[:address].downcase)
    failure(404, "Can't find user with address #{params[:address]}") if user.nil?

    user.top_scenes_visited.to_json
  end

  get '/users/:address/activity/scenes_visited' do
    user = Models::User.find(address: params[:address].downcase)
    failure(404, "Can't find user with address #{params[:address]}") if user.nil?

    user.scenes_visited_histogram.to_json
  end

  get '/users/:address/activity/time_spent' do
    user = Models::User.find(address: params[:address].downcase)
    failure(404, "Can't find user with address #{params[:address]}") if user.nil?

    user.time_spent_histogram.to_json
  end

  get '/users/:address/nfts' do
    user = Models::User.find(address: params[:address].downcase)
    failure(404, "Can't find user with address #{params[:address]}") if user.nil?

    nfts = user.nfts
    base_attributes = {
      address: params[:address],
      name: user.name,
      avatar_url: user.avatar_url,
    }

    if nfts
      base_attributes.merge(
        {
          owns_nfts: true,
          owns_dclens: nfts.owns_dclens,
          owns_land: nfts.owns_land,
          owns_wearables: nfts.owns_wearables,
          total_dclens: nfts.total_dclens,
          total_lands: nfts.total_lands,
          total_wearables: nfts.total_wearables,
          first_dclens_acquired_at: nfts.first_dclens_acquired_at.to_s,
          first_land_acquired_at: nfts.first_land_acquired_at.to_s,
          first_wearable_acquired_at: nfts.first_wearable_acquired_at.to_s,
          participant_in_genesis_auction: nfts.participated_in_genesis_auction?,
          og_user: nfts.og?
        }
      ).to_json
    else
      base_attributes.merge({ owns_nfts: false }).to_json
    end
  end

  get '/users/:address/dao_activity' do
    user = Models::User.find(address: params[:address].downcase)
    failure(404, "Can't find user with address #{params[:address]}") if user.nil?

    dao_activity = user.dao_activity
    base_attributes = {
      address: params[:address],
      name: user.name,
      avatar_url: user.avatar_url
    }

    # TODO: this pattern of parsing json just to immediately
    # turn it back to json is fucking insane. surely there's a better way
    if dao_activity
      # it can be the user has a dao_activity model but no actual activity.
      # this happens (as far as i have seen) in cases where the user is a
      # collection creator but has never voted / taken other actions
      delegators = (user.dao_activity&.delegators || "").split(';').map do |d|
        d_user = Models::User.find(address: d.downcase)

        {
          address: d,
          dao_user: d_user&.dao_member? || false,
          name: d_user&.name,
          avatar_url: d_user&.avatar_url,
          vp: d_user&.dao_activity&.total_vp
        }
      end

      base_attributes.merge(
        {
          dao_member: true,
          title: dao_activity.title,
          total_vp: dao_activity.total_vp || 0,
          delegated_vp: dao_activity.delegated_vp || 0,
          delegators: delegators,
          delegate: dao_activity.delegate,
          votes: {
            total_votes: dao_activity.votes_count || 0,
            first_vote_cast_at: dao_activity.first_vote_cast_at.to_s,
            latest_vote_cast_at: dao_activity.latest_vote_cast_at.to_s,
          },
          grants: dao_activity.grants,
          proposals: {
            count: dao_activity.proposals_count || 0,
            data: JSON.parse(dao_activity.proposals_json || '[]')
          },
          active_dao_committee_member: dao_activity.active_dao_committee_member,
          teams: JSON.parse(dao_activity.teams_json || '[]'),
          collection_creator: dao_activity.collection_creator,
          collections: JSON.parse(dao_activity.collections_json || '[]')
        }
      ).to_json
    else
      base_attributes.merge({ dao_member: false }).to_json
    end
  end

  get '/peer_status' do
    # NOTE: maybe we want to provide more dates later
    # but for now just use yesterday's data
    date = Date.today - 1

    Serializers::PeerStatus.serialize(api_responses).to_json
  end

  private

  def dcl_property_rentals_api(endpoint, params = {})
    url = "https://www.dcl-property.rentals/api/#{endpoint}"
    response = Adapters::Base.get(url, params)

    halt(500, response.failure) if response.failure?
    response.success.to_json
  end

  def failure(status_code, msg)
    halt [status_code, { msg: msg}.to_json]
  end

  def notify_telegram(lvl, msg)
    Services::TelegramOperator.notify(level: lvl, message: msg)
  end

  def fetch_valid_api_key(env, ip_address)
    key = env["HTTP_API_KEY"]
    return unless key

    api_key = Models::ApiKey.find(key: key)
    return unless api_key

    endpoint = env["REQUEST_PATH"]
    log_params = {
      endpoint: endpoint,
      ip_address: ip_address,
      key: key,
      query_params_json: params.to_json
    }

    if api_key.expired?
      expired_msg = "Your API key '#{key}' has expired"
      Models::ApiKeyAccessLog.create(log_params.merge(response: 498))
      halt 498, { msg: expired_msg }.to_json
    end

    unless api_key.permitted?(endpoint)
      unauthorized_msg = "Your API key '#{key}' is not authorized to access #{endpoint}"
      Models::ApiKeyAccessLog.create(log_params.merge(response: 401))
      halt 401, { msg: unauthorized_msg }.to_json
    end

    # TODO: requests per time period
    # rate_limited_msg = "Your API key '#{key}' has made too many requests and is timed out"
    # return halt 403, { msg: rate_limited_msg }.to_json if api_key.rate_limited?

    # log api_key usage
    Models::ApiKeyAccessLog.create(log_params.merge(response: 200))

    true
  end
end
