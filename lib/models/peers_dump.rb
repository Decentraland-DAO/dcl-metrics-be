# primary_key :id
# Jsonb   :data_json, null: false
# Time    :created_at,  null: false

module Models
  class PeersDump < Sequel::Model(:peers_dump)
    def data
      JSON.parse(data_json)
    end
  end
end
