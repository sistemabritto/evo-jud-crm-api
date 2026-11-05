# evo-jud-crm: funil de tráfego (atribuição de origem, eventos por contato e métricas de anúncio).
class CreateTrackingTables < ActiveRecord::Migration[7.1]
  def change
    create_table :tracking_events, id: :uuid do |t|
      t.uuid :contact_id, null: false
      t.uuid :conversation_id
      t.string :stage, null: false
      t.datetime :occurred_at, null: false
      t.bigint :value_cents
      t.string :source, null: false, default: 'crm'
      t.string :external_id
      t.jsonb :metadata, null: false, default: {}
      t.datetime :capi_sent_at
      t.timestamps
    end
    add_index :tracking_events, %i[contact_id stage], unique: true
    add_index :tracking_events, %i[stage occurred_at]

    create_table :tracking_ad_metrics, id: :uuid do |t|
      t.string :platform, null: false
      t.date :date, null: false
      t.string :campaign_id, null: false
      t.string :campaign_name
      t.bigint :spend_cents, null: false, default: 0
      t.bigint :impressions, null: false, default: 0
      t.bigint :clicks, null: false, default: 0
      t.bigint :conversations, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :tracking_ad_metrics, %i[platform date campaign_id], unique: true
  end
end
