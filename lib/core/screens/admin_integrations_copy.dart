import 'package:flutter/widgets.dart';

/// Copy EN/ES/PT tipada de la superficie de integraciones 0.20.
///
/// No se decide por región ni por dispositivo: sigue el locale efectivo de la
/// aplicación igual que el resto de superficies localizadas.
final class AdminIntegrationsCopy {
  final String _lang;

  const AdminIntegrationsCopy._(this._lang);

  factory AdminIntegrationsCopy.of(BuildContext context) =>
      AdminIntegrationsCopy._(
        switch (Localizations.localeOf(context).languageCode.toLowerCase()) {
          'es' => 'es',
          'pt' => 'pt',
          _ => 'en',
        },
      );

  // En/es/pt: cada texto define los tres; el que no aplica nunca se evalúa.
  String _t(String en, String es, String pt) => switch (_lang) {
    'es' => es,
    'pt' => pt,
    _ => en,
  };

  String get screenTitle => _t(
    'Server integrations',
    'Integraciones del servidor',
    'Integrações do servidor',
  );
  String get entryTitle => _t(
    'Server integrations',
    'Integraciones del servidor',
    'Integrações do servidor',
  );
  String get entryBody => _t(
    'Manual MCP, OAuth, webhooks and server-side A2A status.',
    'MCP manual, OAuth, webhooks y estado A2A del servidor.',
    'MCP manual, OAuth, webhooks e estado A2A do servidor.',
  );
  String get sectionLabel => _t(
    'Integration sections',
    'Secciones de integraciones',
    'Seções de integrações',
  );
  String get mcpTab => 'MCP';
  String get webhooksTab => 'Webhooks';
  String get serverTab => _t('Server', 'Servidor', 'Servidor');
  String get readOnly => _t(
    'This instance is read-only. You can inspect state, but server changes are disabled.',
    'Esta instancia es de solo lectura. Puedes consultar el estado, pero los cambios del servidor están desactivados.',
    'Esta instância é somente leitura. Você pode consultar o estado, mas as alterações do servidor estão desativadas.',
  );
  String get refresh => _t('Refresh', 'Actualizar', 'Atualizar');
  String get retry => _t('Retry', 'Reintentar', 'Tentar novamente');
  String get cancel => _t('Cancel', 'Cancelar', 'Cancelar');
  String get close => _t('Close', 'Cerrar', 'Fechar');
  String get done => _t('Done', 'Listo', 'Concluído');
  String get copy => _t('Copy', 'Copiar', 'Copiar');
  String get copied => _t('Copied.', 'Copiado.', 'Copiado.');
  String get delete => _t('Delete', 'Eliminar', 'Excluir');
  String get moreOptions => _t('More options', 'Más opciones', 'Mais opções');

  String get mcpIntro => _t(
    'Add a server with the same individual create contract as Hermes Desktop. Values entered here are sent once and are not saved by the app.',
    'Añade un servidor con el mismo contrato de alta individual de Hermes Desktop. Los valores introducidos se envían una vez y la app no los guarda.',
    'Adicione um servidor com o mesmo contrato de cadastro individual do Hermes Desktop. Os valores informados são enviados uma única vez e não são salvos pelo app.',
  );
  String get addMcp => _t(
    'Add MCP server manually',
    'Añadir servidor MCP manualmente',
    'Adicionar servidor MCP manualmente',
  );
  String get addMcpBody => _t(
    'Guided setup for a local command or an HTTP endpoint.',
    'Configuración guiada para un comando local o un endpoint HTTP.',
    'Configuração guiada para um comando local ou um endpoint HTTP.',
  );
  String get noMcpPut => _t(
    'Existing servers are never edited by replacing the full MCP map, because redacted credentials could be lost.',
    'Los servidores existentes nunca se editan reemplazando el mapa MCP completo, porque podrían perderse credenciales redactadas.',
    'Servidores existentes nunca são editados substituindo o mapa MCP completo, porque credenciais mascaradas poderiam ser perdidas.',
  );
  String get manualMcpUnavailable => _t(
    'This Hermes version does not publish individual MCP provisioning.',
    'Esta versión de Hermes no publica el alta individual de MCP.',
    'Esta versão do Hermes não publica o provisionamento individual de MCP.',
  );
  String get mcpFormTitle => _t(
    'New MCP server',
    'Nuevo servidor MCP',
    'Novo servidor MCP',
  );
  String get transport => _t('Transport', 'Transporte', 'Transporte');
  String get stdio => _t('Local command', 'Comando local', 'Comando local');
  String get http => 'HTTP';
  String get name => _t('Name', 'Nombre', 'Nome');
  String get nameHint => _t('e.g. reports', 'p. ej. reports', 'ex.: reports');
  String get command => _t('Command', 'Comando', 'Comando');
  String get commandHint => _t('e.g. npx', 'p. ej. npx', 'ex.: npx');
  String get arguments => _t('Arguments', 'Argumentos', 'Argumentos');
  String get argumentsHint => _t(
    'One argument per line. No shell parsing is applied.',
    'Un argumento por línea. No se interpreta mediante un shell.',
    'Um argumento por linha. Nada é interpretado por shell.',
  );
  String get environment => _t(
    'Environment variables',
    'Variables de entorno',
    'Variáveis de ambiente',
  );
  String get environmentHint => _t(
    'Values remain in memory only until this form is submitted or closed.',
    'Los valores solo permanecen en memoria hasta enviar o cerrar este formulario.',
    'Os valores permanecem na memória apenas até enviar ou fechar este formulário.',
  );
  String get variableName => _t('Variable', 'Variable', 'Variável');
  String get variableValue => _t('Value', 'Valor', 'Valor');
  String get addVariable => _t(
    'Add variable',
    'Añadir variable',
    'Adicionar variável',
  );
  String get removeVariable => _t(
    'Remove variable',
    'Quitar variable',
    'Remover variável',
  );
  String get endpointUrl => _t('MCP URL', 'URL de MCP', 'URL do MCP');
  String get endpointHint => _t(
    'HTTPS, or HTTP only on a private LAN/Tailscale address.',
    'HTTPS, o HTTP únicamente en una dirección privada LAN/Tailscale.',
    'HTTPS, ou HTTP somente em um endereço privado de LAN/Tailscale.',
  );
  String get authentication => _t(
    'Authentication',
    'Autenticación',
    'Autenticação',
  );
  String get authNone => _t('None', 'Ninguna', 'Nenhuma');
  String get authHeader => _t(
    'Bearer header',
    'Cabecera Bearer',
    'Cabeçalho Bearer',
  );
  String get authOauth => _t(
    'OAuth in browser',
    'OAuth en navegador',
    'OAuth no navegador',
  );
  String get bearerToken => _t('Bearer token', 'Token Bearer', 'Token Bearer');
  String get bearerHint => _t(
    'Sent once to Hermes and never stored by the app.',
    'Se envía una vez a Hermes y la app nunca lo guarda.',
    'Enviado uma vez ao Hermes e nunca armazenado pelo app.',
  );
  String get createMcp => _t(
    'Add server',
    'Añadir servidor',
    'Adicionar servidor',
  );
  String get mcpCreated => _t(
    'MCP server added.',
    'Servidor MCP añadido.',
    'Servidor MCP adicionado.',
  );
  String get invalidForm => _t(
    'Check the highlighted fields and their examples.',
    'Revisa los campos marcados y sus ejemplos.',
    'Verifique os campos destacados e seus exemplos.',
  );
  String get incompleteEnvironment => _t(
    'Each environment row needs both a variable and a value.',
    'Cada fila de entorno necesita una variable y un valor.',
    'Cada linha de ambiente precisa de uma variável e de um valor.',
  );
  String get authorize => _t(
    'Authorize OAuth',
    'Autorizar OAuth',
    'Autorizar OAuth',
  );

  String get oauthTitle => _t(
    'Authorize MCP server',
    'Autorizar servidor MCP',
    'Autorizar servidor MCP',
  );
  String get oauthBody => _t(
    'Hermes receives the callback. This app only opens the authorization page and checks the short-lived flow while this window is visible.',
    'Hermes recibe el callback. Esta app solo abre la página de autorización y comprueba el flujo temporal mientras esta ventana está visible.',
    'O Hermes recebe o callback. Este app apenas abre a página de autorização e verifica o fluxo temporário enquanto esta janela estiver visível.',
  );
  String get openBrowser => _t(
    'Open authorization page',
    'Abrir página de autorização',
    'Abrir página de autorização',
  );
  String get openingBrowserFailed => _t(
    'Android could not open the authorization page.',
    'Android no pudo abrir la página de autorización.',
    'O Android não conseguiu abrir a página de autorização.',
  );
  String get oauthWaiting => _t(
    'Waiting for authorization…',
    'Esperando autorización…',
    'Aguardando autorização…',
  );
  String get oauthApproved => _t(
    'Authorization complete.',
    'Autorización completada.',
    'Autorização concluída.',
  );
  String get oauthError => _t(
    'Hermes reported an authorization error.',
    'Hermes indicó un error de autorización.',
    'O Hermes indicou um erro de autorização.',
  );
  String get oauthExpired => _t(
    'This authorization flow expired. Start it again.',
    'Este flujo de autorización caducó. Inícialo de nuevo.',
    'Este fluxo de autorização expirou. Inicie-o novamente.',
  );
  String get oauthUnknown => _t(
    'Hermes returned an unknown authorization state.',
    'Hermes devolvió un estado de autorización desconocido.',
    'O Hermes retornou um estado de autorização desconhecido.',
  );
  String oauthTools(int count) => _t(
    '$count ${count == 1 ? 'tool' : 'tools'} available',
    '$count ${count == 1 ? 'herramienta disponible' : 'herramientas disponibles'}',
    '$count ${count == 1 ? 'ferramenta disponível' : 'ferramentas disponíveis'}',
  );

  String get webhooksIntro => _t(
    'Webhooks are an official Hermes gateway platform. Subscriptions hot-reload after the receiver is enabled.',
    'Webhooks es una plataforma oficial del Gateway de Hermes. Las suscripciones se recargan en caliente cuando el receptor está activo.',
    'Webhooks é uma plataforma oficial do Gateway do Hermes. As assinaturas são recarregadas automaticamente quando o receptor está ativo.',
  );
  String get webhooksUnavailable => _t(
    'This Hermes version does not publish webhook administration.',
    'Esta versión de Hermes no publica la administración de webhooks.',
    'Esta versão do Hermes não publica a administração de webhooks.',
  );
  String get webhookLoadFailed => _t(
    'Webhooks could not be loaded.',
    'No se pudieron cargar los webhooks.',
    'Não foi possível carregar os webhooks.',
  );
  String get webhooksDisabled => _t(
    'Webhook receiver disabled',
    'Receptor de webhooks desactivado',
    'Receptor de webhooks desativado',
  );
  String get webhooksDisabledBody => _t(
    'Enable it to accept incoming HTTP events. Hermes may need to restart the Gateway.',
    'Actívalo para aceptar eventos HTTP entrantes. Hermes puede necesitar reiniciar el Gateway.',
    'Ative-o para aceitar eventos HTTP de entrada. O Hermes pode precisar reiniciar o Gateway.',
  );
  String get enableWebhooks => _t(
    'Enable webhooks',
    'Activar webhooks',
    'Ativar webhooks',
  );
  String get enableWarningTitle => _t(
    'Enable webhook receiver?',
    '¿Activar el receptor de webhooks?',
    'Ativar o receptor de webhooks?',
  );
  String get enableWarningBody => _t(
    'Hermes may restart the Gateway. Active chats can reconnect while the receiver comes online.',
    'Hermes puede reiniciar el Gateway. Los chats activos podrán reconectarse mientras arranca el receptor.',
    'O Hermes pode reiniciar o Gateway. Chats ativos poderão se reconectar enquanto o receptor inicializa.',
  );
  String get enable => _t('Enable', 'Activar', 'Ativar');
  String get disable => _t('Disable', 'Desactivar', 'Desativar');
  String get webhooksEnabledRestarting => _t(
    'Webhooks enabled; the Gateway is restarting.',
    'Webhooks activados; el Gateway se está reiniciando.',
    'Webhooks ativados; o Gateway está reiniciando.',
  );
  String get webhooksEnabled => _t(
    'Webhooks enabled.',
    'Webhooks activados.',
    'Webhooks ativados.',
  );
  String get webhooksNeedRestart => _t(
    'Webhooks are enabled, but the Gateway still needs a restart.',
    'Webhooks están activados, pero el Gateway todavía necesita reiniciarse.',
    'Os webhooks estão ativados, mas o Gateway ainda precisa ser reiniciado.',
  );
  String get addWebhook => _t(
    'New subscription',
    'Nueva suscripción',
    'Nova assinatura',
  );
  String get addWebhookBody => _t(
    'Create an authenticated route and copy its one-time secret.',
    'Crea una ruta autenticada y copia su secreto de una sola visualización.',
    'Crie uma rota autenticada e copie o segredo de uso único.',
  );
  String get noWebhooks => _t(
    'No webhook subscriptions yet.',
    'Todavía no hay suscripciones webhook.',
    'Ainda não há assinaturas de webhook.',
  );
  String get webhookFormTitle => _t(
    'New webhook subscription',
    'Nueva suscripción webhook',
    'Nova assinatura de webhook',
  );
  String get description => _t('Description', 'Descripción', 'Descrição');
  String get descriptionHint => _t(
    'What this route does (optional)',
    'Qué hace esta ruta (opcional)',
    'O que esta rota faz (opcional)',
  );
  String get prompt => _t('Prompt', 'Instrucciones', 'Instruções');
  String get promptHint => _t(
    'Instructions for Hermes when this event arrives (optional)',
    'Instrucciones para Hermes cuando llegue el evento (opcional)',
    'Instruções para o Hermes quando este evento chegar (opcional)',
  );
  String get events => _t('Events', 'Eventos', 'Eventos');
  String get eventsHint => _t(
    'Comma-separated; empty accepts all events',
    'Separados por comas; vacío acepta todos los eventos',
    'Separados por vírgula; vazio aceita todos os eventos',
  );
  String get skills => _t('Skills', 'Skills', 'Skills');
  String get skillsHint => _t(
    'Optional, comma-separated skill names',
    'Opcional, nombres de skills separados por comas',
    'Opcional, nomes de skills separados por vírgulas',
  );
  String get delivery => _t('Deliver to', 'Entregar a', 'Entregar em');
  String get deliverOnly => _t(
    'Deliver payload only',
    'Entregar solo el payload',
    'Entregar somente o payload',
  );
  String get deliverOnlyHint => _t(
    'Skips the agent response for channel delivery.',
    'Omite la respuesta del agente al entregar en un canal.',
    'Omite a resposta do agente ao entregar em um canal.',
  );
  String deliveryLabel(String value) => switch (value) {
    'log' => _t('Log only', 'Solo registro', 'Somente log'),
    'telegram' => 'Telegram',
    'discord' => 'Discord',
    'slack' => 'Slack',
    'email' => _t('Email', 'Correo', 'E-mail'),
    'github_comment' => _t(
      'GitHub comment',
      'Comentario de GitHub',
      'Comentário do GitHub',
    ),
    _ => value,
  };
  String get createWebhook => _t('Create', 'Crear', 'Criar');
  String get webhookCreated => _t(
    'Subscription created.',
    'Suscripción creada.',
    'Assinatura criada.',
  );
  String get duplicateWebhook => _t(
    'A webhook with that name already exists. Delete it explicitly before creating a replacement.',
    'Ya existe un webhook con ese nombre. Elimínalo de forma explícita antes de crear otro.',
    'Já existe um webhook com esse nome. Exclua-o explicitamente antes de criar outro.',
  );
  String get secretTitle => _t(
    'Copy the webhook secret now',
    'Copia ahora el secreto del webhook',
    'Copie agora o segredo do webhook',
  );
  String get secretBody => _t(
    'Hermes shows this secret only once. Closing this receipt removes it from the app and it cannot be recovered here.',
    'Hermes solo muestra este secreto una vez. Al cerrar este recibo se elimina de la app y no podrá recuperarse aquí.',
    'O Hermes mostra este segredo apenas uma vez. Ao fechar este recibo, ele é removido do app e não poderá ser recuperado aqui.',
  );
  String get webhookUrl => _t(
    'Webhook URL',
    'URL del webhook',
    'URL do webhook',
  );
  String get webhookSecret => _t(
    'One-time secret',
    'Secreto de un solo uso',
    'Segredo de uso único',
  );
  String get deleteWebhookTitle => _t(
    'Delete webhook?',
    '¿Eliminar webhook?',
    'Excluir webhook?',
  );
  String get deleteWebhookBody => _t(
    'This permanently removes the subscription. Existing integrations will stop working.',
    'Esto elimina la suscripción de forma permanente. Las integraciones existentes dejarán de funcionar.',
    'Isso exclui a assinatura de forma permanente. As integrações existentes deixarão de funcionar.',
  );
  String get webhookDeleted => _t(
    'Webhook deleted.',
    'Webhook eliminado.',
    'Webhook excluído.',
  );
  String webhookSubtitle(String deliver, List<String> events) {
    final eventText = events.isEmpty
        ? _t('all events', 'todos los eventos', 'todos os eventos')
        : events.join(', ');
    return '${deliveryLabel(deliver)} · $eventText';
  }

  String get a2aIntro => _t(
    'A2A runs entirely on the Hermes host. Android only reports the official platform status and does not add another protocol client.',
    'A2A funciona íntegramente en el host de Hermes. Android solo muestra el estado oficial de la plataforma y no añade otro cliente de protocolo.',
    'O A2A funciona inteiramente no host do Hermes. O Android apenas mostra o estado oficial da plataforma e não adiciona outro cliente de protocolo.',
  );
  String get a2aUnavailable => _t(
    'This server does not publish its platform catalog.',
    'Este servidor no publica su catálogo de plataformas.',
    'Este servidor não publica o catálogo de plataformas.',
  );
  String get a2aNotPublished => _t(
    'A2A is not published by this Hermes installation.',
    'Esta instalación de Hermes no publica A2A.',
    'Esta instalação do Hermes não publica A2A.',
  );
  String get a2aTitle => 'A2A';
  String get configured => _t('Configured', 'Configurado', 'Configurado');
  String get notConfigured => _t(
    'Not configured',
    'Sin configurar',
    'Não configurado',
  );
  String get running => _t(
    'Gateway running',
    'Gateway en ejecución',
    'Gateway em execução',
  );
  String get stopped => _t(
    'Gateway stopped',
    'Gateway detenido',
    'Gateway parado',
  );
  String get active => _t('Enabled', 'Activo', 'Ativo');
  String get inactive => _t('Disabled', 'Desactivado', 'Desativado');
  String a2aState(String state) => switch (state) {
    'connected' => _t('Connected', 'Conectado', 'Conectado'),
    'connecting' => _t('Connecting', 'Conectando', 'Conectando'),
    'retrying' => _t('Retrying', 'Reintentando', 'Tentando novamente'),
    'pending_restart' => _t(
      'Pending restart',
      'Reinicio pendiente',
      'Reinício pendente',
    ),
    'not_configured' => _t(
      'Not configured',
      'Sin configurar',
      'Não configurado',
    ),
    'gateway_stopped' => _t(
      'Gateway stopped',
      'Gateway detenido',
      'Gateway parado',
    ),
    'startup_failed' => _t(
      'Startup failed',
      'Error al iniciar',
      'Falha ao iniciar',
    ),
    'disconnected' => _t('Disconnected', 'Desconectado', 'Desconectado'),
    'fatal' => _t('Fatal error', 'Error fatal', 'Erro fatal'),
    'disabled' => _t('Disabled', 'Desactivado', 'Desativado'),
    _ => _t('Status unavailable', 'Estado no disponible', 'Status indisponível'),
  };

  String get unsupported => _t(
    'This operation is not available on the connected Hermes version.',
    'Esta operación no está disponible en la versión de Hermes conectada.',
    'Esta operação não está disponível na versão do Hermes conectada.',
  );
  String get forbidden => _t(
    'The current Dashboard credentials do not allow this operation.',
    'Las credenciales actuales del Dashboard no permiten esta operación.',
    'As credenciais atuais do Dashboard não permitem esta operação.',
  );
  String get unavailable => _t(
    'Hermes could not complete the operation right now.',
    'Hermes no pudo completar la operación ahora mismo.',
    'O Hermes não pôde concluir a operação neste momento.',
  );
  String get invalidResponse => _t(
    'Hermes returned an invalid integration response.',
    'Hermes devolvió una respuesta de integración no válida.',
    'O Hermes retornou uma resposta de integração inválida.',
  );
  String get rejected => _t(
    'Hermes rejected the values or the server state changed.',
    'Hermes rechazó los valores o cambió el estado del servidor.',
    'O Hermes rejeitou os valores ou o estado do servidor mudou.',
  );
}
