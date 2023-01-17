module Adapters
  class Base
    include Dry::Monads[:result]

    JSON_FORMAT = 'json'
    CSV_FORMAT = 'csv'

    def self.get(url, params = {})
      new(url, params).get
    end

    def initialize(url, params)
      @url = url
      @params = params
      @format = params.fetch(:response_format) { JSON_FORMAT }
    end

    def get
      begin
        response = Faraday.get(url, params)

        Services::RequestLogger.call(status: response.status, url: url, params: params)
        return Failure('request was not successful') unless response.status == 200

        data = case format
               when JSON_FORMAT
                 JSON.parse(response.body)
               when CSV_FORMAT
                 CSV.parse(response.body)
               else
                 response.body
               end
      rescue JSON::ParserError, Faraday::ConnectionFailed => e
        Services::RequestLogger.call(status: 500, url: url, params: params)
        print "error when fetching from '#{url}'\n"
        return Failure(e.message)
      end

      Success(data)
    end

    private
    attr_reader :url, :params, :format
  end
end
