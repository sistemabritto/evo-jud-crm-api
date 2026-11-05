# evo-jud-crm: clique em anúncio do Google que levou ao WhatsApp pelo site. O site gera uma referência
# curta que vai no fim da mensagem ([GINV1-AB12C]) e manda o gclid ao CRM; a conversa casa com o clique.
class CreateTrackingClickRefs < ActiveRecord::Migration[7.1]
  def change
    create_table :tracking_click_refs, id: :uuid do |t|
      t.string :ref, null: false
      t.string :gclid, null: false
      t.string :code
      t.timestamps
    end
    add_index :tracking_click_refs, :ref, unique: true
    add_index :tracking_click_refs, :created_at
  end
end
