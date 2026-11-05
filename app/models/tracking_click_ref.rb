# evo-jud-crm: referência curta do site → gclid do clique no anúncio do Google.
class TrackingClickRef < ApplicationRecord
  REF = /\A[A-Z0-9]{5}\z/
  GCLID = /\A[\w-]{10,250}\z/
  validates :ref, format: { with: REF }, uniqueness: true
  validates :gclid, format: { with: GCLID }
end
