# evo-jud-crm: card que entra numa etapa mapeada (Tracking) vira marco do funil.
module Tracking
  class PipelineStageJob < ApplicationJob
    queue_as :low
    KINDS = { meeting: 'reuniao_agendada', contract: 'contrato_assinado', payment: 'pagamento_efetuado' }.freeze

    def perform(pipeline_item_id)
      item = PipelineItem.find_by(id: pipeline_item_id)
      return unless item

      contact = item.try(:contact) || item.conversation&.contact
      return unless contact

      KINDS.each do |kind, stage|
        next unless Tracking::Config.stage_ids(kind).include?(item.pipeline_stage_id.to_s)

        Tracking::Recorder.record!(contact: contact, stage: stage, occurred_at: Time.current, conversation: item.conversation,
                                   source: 'funil', metadata: { pipeline_stage_id: item.pipeline_stage_id })
      end
    end
  end
end
