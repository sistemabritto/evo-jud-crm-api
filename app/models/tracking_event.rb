# evo-jud-crm: um marco do funil por contato (primeira ocorrência de cada etapa).
class TrackingEvent < ApplicationRecord
  STAGES = %w[conversa_iniciada link_agendamento_enviado reuniao_agendada contrato_assinado pagamento_efetuado].freeze

  belongs_to :contact
  belongs_to :conversation, optional: true

  validates :stage, inclusion: { in: STAGES }
  validates :occurred_at, presence: true
end
