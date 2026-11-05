namespace :tracking do
  desc 'evo-jud-crm: monta o funil de tráfego a partir do histórico (idempotente)'
  task backfill: :environment do
    puts Tracking::Backfill.run!.inspect
  end

  desc 'evo-jud-crm: sincroniza agora as métricas do Meta'
  task meta_sync: :environment do
    puts "linhas: #{Tracking::MetaApi.sync_insights!}"
  end
end
