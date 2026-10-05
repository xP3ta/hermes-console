import 'dart:math';

/// Starter ideas for the new-project dialog, ported from Hermes Desktop
/// (`apps/desktop/src/lib/project-idea-templates.ts`). A chip prefills the
/// IDEA.md text; a random handful is shown and the dice reshuffles them.
/// Pure content with a Spanish and an English version of each idea.
final class ProjectIdeaTemplate {
  final String emoji;
  final String labelEn;
  final String ideaEn;
  final String labelEs;
  final String ideaEs;

  const ProjectIdeaTemplate(
    this.emoji,
    this.labelEn,
    this.ideaEn,
    this.labelEs,
    this.ideaEs,
  );

  String label(String languageCode) => languageCode == 'es' ? labelEs : labelEn;

  String idea(String languageCode) => languageCode == 'es' ? ideaEs : ideaEn;
}

const List<ProjectIdeaTemplate> projectIdeaTemplates = [
  ProjectIdeaTemplate(
    '🎮',
    'Game jam',
    'A tiny browser game built in a weekend.\n\n- One core mechanic, juicy '
        'feedback\n- No build step — single HTML/JS file\n- Playable in under '
        '60 seconds',
    'Game jam',
    'Un juego de navegador pequeño, hecho en un fin de semana.\n\n- Una '
        'mecánica principal con buen feedback\n- Sin compilación: un solo '
        'archivo HTML/JS\n- Jugable en menos de 60 segundos',
  ),
  ProjectIdeaTemplate(
    '📚',
    'Novel',
    'A novel-in-progress.\n\n- Track chapters, characters, and timeline\n- '
        'Daily word-count goal\n- Keep research notes beside the draft',
    'Novela',
    'Una novela en marcha.\n\n- Capítulos, personajes y cronología al día\n- '
        'Objetivo diario de palabras\n- Notas de documentación junto al '
        'borrador',
  ),
  ProjectIdeaTemplate(
    '🤖',
    'Discord bot',
    'A Discord bot for a small community.\n\n- Slash commands + a fun daily '
        'ritual\n- Lightweight persistence\n- Deploy somewhere free',
    'Bot de Discord',
    'Un bot de Discord para una comunidad pequeña.\n\n- Comandos con barra y '
        'un ritual diario divertido\n- Persistencia ligera\n- Desplegado en '
        'algún sitio gratis',
  ),
  ProjectIdeaTemplate(
    '📊',
    'Data viz',
    'An interactive visualization of a dataset I care about.\n\n- Pick the '
        'dataset and the one question it answers\n- Clean → chart → '
        'annotate\n- Shareable as a single page',
    'Visualización',
    'Una visualización interactiva de unos datos que me importan.\n\n- Elegir '
        'los datos y la pregunta que responden\n- Limpiar → graficar → '
        'anotar\n- Compartible como una sola página',
  ),
  ProjectIdeaTemplate(
    '🎨',
    'Generative art',
    'A generative art piece.\n\n- One algorithm, lots of seeds\n- Export '
        'high-res stills\n- A gallery of the best outputs',
    'Arte generativo',
    'Una pieza de arte generativo.\n\n- Un algoritmo, muchas semillas\n- '
        'Exportar imágenes en alta resolución\n- Una galería con los mejores '
        'resultados',
  ),
  ProjectIdeaTemplate(
    '🍳',
    'Recipe box',
    'A personal recipe collection.\n\n- Searchable by ingredient and mood\n- '
        'Scale servings on the fly\n- Auto-build a shopping list',
    'Recetario',
    'Una colección personal de recetas.\n\n- Buscar por ingrediente y por '
        'antojo\n- Ajustar las raciones al momento\n- Lista de la compra '
        'automática',
  ),
  ProjectIdeaTemplate(
    '🧪',
    'Research log',
    'A research notebook for an open question.\n\n- Log experiments, '
        'results, and dead ends\n- Cite sources inline\n- Weekly synthesis of '
        'what I learned',
    'Cuaderno de investigación',
    'Un cuaderno de investigación para una pregunta abierta.\n\n- Registrar '
        'experimentos, resultados y callejones sin salida\n- Citar las '
        'fuentes en el texto\n- Resumen semanal de lo aprendido',
  ),
  ProjectIdeaTemplate(
    '💸',
    'Budget tracker',
    'A no-nonsense budget tracker.\n\n- Import transactions, tag them fast\n- '
        'Monthly burn vs. plan\n- One chart that tells the truth',
    'Presupuesto',
    'Un control de gastos sin complicaciones.\n\n- Importar movimientos y '
        'etiquetarlos rápido\n- Gasto mensual frente a lo previsto\n- Un '
        'gráfico que no engaña',
  ),
  ProjectIdeaTemplate(
    '🌱',
    'Habit tracker',
    'A habit tracker that actually sticks.\n\n- A handful of daily '
        'checkboxes\n- Streaks without guilt\n- A calm weekly review',
    'Hábitos',
    'Un registro de hábitos que de verdad se mantenga.\n\n- Unas pocas '
        'casillas diarias\n- Rachas sin culpa\n- Un repaso semanal tranquilo',
  ),
  ProjectIdeaTemplate(
    '🗺️',
    'Trip planner',
    'A trip planner for an upcoming adventure.\n\n- Day-by-day itinerary\n- '
        'Map of pins + notes\n- Packing + budget checklist',
    'Viaje',
    'Un planificador para la próxima aventura.\n\n- Itinerario día a día\n- '
        'Mapa con chinchetas y notas\n- Lista de equipaje y presupuesto',
  ),
  ProjectIdeaTemplate(
    '🎵',
    'Music toy',
    'A little music-making toy.\n\n- One instrument or sequencer\n- Web '
        'Audio, no installs\n- Record + share a loop',
    'Juguete musical',
    'Un pequeño juguete para hacer música.\n\n- Un instrumento o un '
        'secuenciador\n- Web Audio, sin instalar nada\n- Grabar y compartir un '
        'loop',
  ),
  ProjectIdeaTemplate(
    '🧩',
    'Puzzle maker',
    'A generator for a puzzle I love.\n\n- Procedurally make solvable '
        'puzzles\n- Difficulty dial\n- Printable + playable',
    'Puzles',
    'Un generador de un tipo de puzle que me encanta.\n\n- Puzles con '
        'solución generados por procedimiento\n- Selector de dificultad\n- '
        'Para imprimir y para jugar',
  ),
  ProjectIdeaTemplate(
    '📝',
    'Digital garden',
    'A digital garden / personal wiki.\n\n- Atomic notes that link to each '
        'other\n- Grows over time, never "done"\n- Publish the public ones',
    'Jardín digital',
    'Un jardín digital o wiki personal.\n\n- Notas atómicas enlazadas entre '
        'sí\n- Crece con el tiempo, nunca está «terminado»\n- Publicar las que '
        'sean públicas',
  ),
  ProjectIdeaTemplate(
    '🛰️',
    'API wrapper',
    'A clean wrapper around an API I keep reaching for.\n\n- Typed client + '
        'sensible defaults\n- One example per endpoint\n- Publish it',
    'Cliente de API',
    'Un cliente limpio para una API que uso a menudo.\n\n- Cliente tipado con '
        'valores por defecto sensatos\n- Un ejemplo por endpoint\n- '
        'Publicarlo',
  ),
  ProjectIdeaTemplate(
    '🏋️',
    'Workout plan',
    'A workout planner / logger.\n\n- Build a weekly split\n- Log sets fast '
        'on mobile\n- Track progress over months',
    'Entrenamiento',
    'Un planificador y registro de entrenamientos.\n\n- Montar la rutina '
        'semanal\n- Apuntar series rápido desde el móvil\n- Ver el progreso a '
        'lo largo de los meses',
  ),
  ProjectIdeaTemplate(
    '🧠',
    'Flashcards',
    'A spaced-repetition flashcard app.\n\n- Quick card capture\n- Simple '
        'SM-2 scheduling\n- A daily review that fits in 5 minutes',
    'Tarjetas de estudio',
    'Una app de tarjetas con repetición espaciada.\n\n- Crear tarjetas al '
        'vuelo\n- Planificación SM-2 sencilla\n- Un repaso diario que cabe en '
        '5 minutos',
  ),
  ProjectIdeaTemplate(
    '✍️',
    'Screenplay',
    'A short screenplay.\n\n- Logline → beats → scenes\n- Proper format, '
        'distraction-free\n- A table read by the end',
    'Guion',
    'Un cortometraje en guion.\n\n- Logline → puntos clave → escenas\n- '
        'Formato correcto y sin distracciones\n- Una lectura en voz alta al '
        'final',
  ),
  ProjectIdeaTemplate(
    '🔭',
    'Learn-by-building',
    "A project to learn a thing I've been avoiding.\n\n- Smallest real thing "
        'that teaches it\n- Notes on every gotcha\n- A writeup when it works',
    'Aprender haciendo',
    'Un proyecto para aprender algo que llevo tiempo esquivando.\n\n- Lo más '
        'pequeño y real que lo enseñe\n- Notas de cada trampa\n- Un resumen '
        'cuando funcione',
  ),
];

/// A shuffled slice of the pool (Desktop `randomIdeaTemplates`).
List<ProjectIdeaTemplate> randomProjectIdeaTemplates({
  int count = 6,
  Random? random,
}) {
  final pool = [...projectIdeaTemplates]..shuffle(random ?? Random());
  return pool.take(min(count, pool.length)).toList(growable: false);
}
