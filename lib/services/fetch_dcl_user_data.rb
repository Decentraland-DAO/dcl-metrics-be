module Services
  class FetchDclUserData
    def self.call(addresses:)
      new(addresses).call
    end

    def initialize(addresses)
      @addresses = addresses.uniq
      @users = []
    end

    # TODO: this probably makes more sense as a job that runs once an hour or so
    # and calls update_or_create on all users in the last hour - but users need
    # to be created before that happens
    def call
      # TODO: after users have been added
      # find_known_users
      create_users_from_unknown_addresses
      return users if all_data_fetched?

      # give it another try for good measure
      # NOTE: wow this is janky af
      remaining_addresses.each { |address| create_users_from_unknown_addresses([address]) }
      users
    end

    private
    attr_reader :addresses
    attr_accessor :users

    def all_data_fetched?
      addresses.count == users.count
    end

    def remaining_addresses
      addresses - users.map { |u| u[:address] }
    end

    # def find_known_users
    #   Models::Users.where(address: remaining_addresses).each do |user|
    #     users.push({
    #       address: user.address,
    #       avatar_url: user.avatar_url,
    #       guest_user: user.guest_user?,
    #       name: user.name,
    #       verified_user: user.verified_user?
    #     })
    #   end
    # end

    def create_users_from_unknown_addresses(specified_addresses = [])
      to_fetch = specified_addresses.empty? ? remaining_addresses : specified_addresses

      to_fetch.each_slice(40) do |batch|
        user_data = Adapters::Dcl::UserProfiles.call(addresses: batch)

        user_data.each do |data|
          next if data.nil?
          next if data.empty?
          user = data['avatars'][0]
          verified_user = user['hasClaimedName']

          # NOTE: guest user has a triple bang - force boolean and then invert it
          users.push({
            address: user['userId'],
            avatar_url: user['avatar']['snapshots']['face256'],
            guest_user: verified_user ? false : !!!user['hasConnectedWeb3'],
            name: user['name'],
            verified_user: verified_user
          })
        end
      end
    end
  end
end