"""What LauncherWidgets.kt draws, for the mock-up's sample content.

Used by widget_shots.py render. Every function here mirrors one branch of
the Kotlin renderer: the same layout, the same views shown or hidden, the
same row counts from the same sizes. The numbers come from the resources;
only the sample content (names, faces, times) is written here.
"""

GOLD, GREEN, AMBER, RED, MUTED, FAINT, INK = (f'@color/lw_{n}' for n in
                                             ('gold', 'green', 'amber', 'red', 'muted', 'faint', 'ink'))


def build(res, r, cells, pixel, face):
    d = res.dimen
    touch = d('@dimen/lw_touch')
    hermes, forja, fable, astra = face('lead'), face('builder'), face('review'), face('scout')

    # ------------------------------------------------------------ shared pieces (LauncherWidgetRenderer)
    def lead_face(src):
        return {'lw_lead_glyph': {'visible': False}, 'lw_lead_face': {'visible': True, 'src': src}}

    def lead_glyph(bg, icon, tint):
        return {'lw_lead_glyph': {'bg': f'@drawable/{bg}', 'src': f'@drawable/{icon}', 'tint': tint}}

    def text(title, sub=None, sub_color=None, sub2=None, sub2_color=None):
        ov = {'lw_title': {'text': title}, 'lw_sub': {'text': sub or ''}, 'lw_sub_row': {'visible': bool(sub)},
              'lw_sub2': {'visible': bool(sub2), 'text': sub2 or ''}}
        if sub_color:
            ov['lw_sub']['color'] = sub_color
        if sub2_color:
            ov['lw_sub2']['color'] = sub2_color
        return ov

    def strip(*parts, card=None):
        ov = {}
        for part in parts:
            for key, value in part.items():
                ov.setdefault(key, {}).update(value)
        if card:
            ov['background'] = {'bg': f'@drawable/{card}'}
        return r.layout('lw_strip', ov)

    # A one-row card: the lead, the text block and what stands at its end
    # share the card's centre line; the padding is the same at both sides and
    # above and below; the lines of text start at one edge; a timer written
    # after a word stands on that word's baseline.
    STRIP_PROBES = [
        {'centres': ['.', 'lw_lead', 'lw_texts', 'lw_end_timer', 'lw_end_time']},
        {'insets': ['lw_lead', ['lw_end_timer', 'lw_end_time', 'lw_texts']]},
        {'insets': ['lw_lead', 'lw_lead'], 'axis': 'y'},
        {'insets': ['lw_texts', 'lw_texts'], 'axis': 'y'},
        {'starts': ['lw_title', 'lw_sub_row', 'lw_sub2']},
        {'baselines': ['lw_sub', 'lw_sub_timer']},
    ]

    def row(src, title, sub, mark=None, timer=None, time=None, sub_color=None, dim=False):
        ov = {'lw_row_glyph': {'visible': False}, 'lw_row_face': {'visible': True, 'src': src},
              'lw_row_title': {'text': title}, 'lw_row_sub': {'text': sub}}
        if mark == 'dot':
            ov['lw_row_mark'] = {'visible': True, 'src': '@drawable/lw_dot', 'tint': None}
        elif mark == 'check':
            ov['lw_row_mark'] = {'visible': True, 'src': '@drawable/lw_ic_check', 'tint': GREEN}
        if timer:
            ov['lw_row_timer'] = {'visible': True, 'text': timer}
        if time:
            ov['lw_row_time'] = {'visible': True, 'text': time}
        if sub_color:
            ov['lw_row_sub']['color'] = sub_color
        if dim:
            ov['lw_row_title']['color'] = FAINT
            ov['lw_row_sub']['color'] = FAINT
            ov['lw_row_face']['alpha'] = 115
            ov.setdefault('lw_row_mark', {})['alpha'] = 115
        return ('lw_row', ov)

    def body_height(height):
        return height - d('@dimen/lw_pad_top') - d('@dimen/lw_pad_bottom') - d('@dimen/lw_head_height') \
            - d('@dimen/lw_head_gap')

    def row_height():
        return max(d('@dimen/lw_row_min'), 36 + 8)

    def with_rows(children, rows, room, lined):
        fit = max(0, min(8, int(room // row_height())))
        rows = rows[:fit]
        if rows and lined:
            children.append(('lw_line', {}))
        for index, item in enumerate(rows):
            if index:
                children.append(('lw_line', {}))
            children.append(item)
        for _ in range(max(0, min(12, int(room // row_height()) - len(rows)))):
            children.append(('lw_fill', {}))
        return children

    def board(icon, label, children, gold=False, right=None, right_color=None, right_icon=False, card='lw_card'):
        ov = {'background': {'bg': f'@drawable/{card}'},
              'lw_head_chip': {'bg': '@drawable/lw_chip_gold' if gold else '@drawable/lw_chip',
                               'src': f'@drawable/{icon}', 'tint': GOLD if gold else MUTED},
              'lw_head_label': {'text': label},
              'lw_head_right': {'visible': right is not None, 'text': right or ''},
              'lw_head_right_icon': {'visible': right_icon and right is not None},
              'lw_body': {'children': children}}
        if right_color:
            ov['lw_head_right']['color'] = right_color
        return r.layout('lw_board', ov)

    # A board. Its head: the chip, the name and the count on one centre line,
    # name and count on one baseline, the same padding at both sides. Its
    # rows, one by one: lead, text block and what stands at the end on the
    # row's centre line; the mark on its line of text; the same padding at
    # both sides of the card and above and below the text; "Ver" centred in
    # its pill. And every row as tall as the others, never under a tap target.
    def board_probes(lead='lw_row_lead'):
        return [
            {'centres': ['lw_head', 'lw_head_chip', 'lw_head_label', 'lw_head_right_icon', 'lw_head_right']},
            {'baselines': ['lw_head_label', 'lw_head_right']},
            {'insets': ['lw_head_chip', ['lw_head_right', 'lw_head_label']]},
            {'starts': ['lw_head', 'lw_body']},
            {'heights': 'lw_row', 'least': touch},
            {'each': 'lw_row', 'name': 'row', 'probes': [
                {'centres': ['.', lead, 'lw_row_texts', 'lw_row_timer', 'lw_row_time', 'lw_row_view']},
                {'centres': ['lw_row_mark', 'lw_row_sub']},
                {'insets': [[lead, 'lw_row_texts'], ['lw_row_view', 'lw_row_timer', 'lw_row_time', 'lw_row_texts']]},
                {'insets': ['lw_row_texts', 'lw_row_texts'], 'axis': 'y', 'frame': 'scope'},
                {'label': 'lw_row_view', 'box': 'lw_row_view', 'sides': True},
            ]},
        ]

    ROW_PROBES = board_probes()

    # ------------------------------------------------------------ Chat rápido
    def quick(width):
        if width >= 250:
            return r.layout('lw_quick_wide', {'lw_quick_glyph': {'visible': False},
                                             'lw_quick_face': {'visible': True, 'src': hermes}})
        # The label stays only while it fits (the estimate LauncherWidgets.kt makes).
        pill = width - 2 * d('@dimen/lw_quick_pad') - d('@dimen/lw_quick_gap') - touch
        needed = 2 * d('@dimen/lw_quick_pill_pad') + d('@dimen/lw_quick_icon') + d('@dimen/lw_quick_icon_gap') \
            + 0.56 * 14 * len(res.string('@string/lw_new')) + 4
        return r.layout('lw_quick_small', {'lw_quick_new_label': {'visible': needed <= pill}})

    QUICK_SMALL = [{'label': 'lw_quick_new_label', 'box': 'lw_quick_new', 'sides': True, 'with': 'lw_quick_voice'}]
    QUICK_WIDE = [{'label': 'lw_quick_hint', 'box': 'lw_quick_new', 'with': 'lw_quick_voice'},
                  {'centres': ['lw_quick_agent', 'lw_quick_new', 'lw_quick_camera', 'lw_quick_voice']}]
    quick_shots = [
        ('Chat rápido 2×1 (mock-up grid)', cells['2x1'], quick(cells['2x1'][0]), QUICK_SMALL),
        ('Chat rápido 2×1 (Pixel)', pixel['2x1'], quick(pixel['2x1'][0]), QUICK_SMALL),
        ('Chat rápido 2×1, short row', (171, 60), quick(171), QUICK_SMALL),
        ('Chat rápido, too narrow for the label', (128, 88), quick(128), []),
        ('Chat rápido 4×1 (mock-up grid)', cells['4x1'], quick(cells['4x1'][0]), QUICK_WIDE),
        ('Chat rápido 4×1 (Pixel)', pixel['4x1'], quick(pixel['4x1'][0]), QUICK_WIDE),
    ]

    # ------------------------------------------------------------ Ahora
    def ask_strip():
        return r.layout('lw_ask_strip', {'lw_ask_glyph': {'visible': False},
                                        'lw_ask_face': {'visible': True, 'src': hermes},
                                        'lw_ask_title': {'text': 'Hermes pide permiso'},
                                        'lw_ask_detail': {'text': 'rm -rf build/'}})

    ASK_PROBES = [{'label': 'lw_button_yes_label', 'box': 'lw_button_yes_label'},
                  {'label': 'lw_button_no_label', 'box': 'lw_button_no_label'},
                  {'label': 'lw_button_open_label', 'box': 'lw_button_open_label'},
                  {'centres': ['lw_button_yes_label', 'lw_button_no_label', 'lw_button_open_label']}]

    run_hermes = row(hermes, 'Hermes', 'Terminal · Prueba con subagentes, herramientas y pensamiento',
                     mark='dot', timer='00:42')
    run_forja = row(forja, 'Forja', 'Responde · Console Devs', mark='dot', timer='02:14')
    done_fable = row(fable, 'Fable', 'Terminó · Diseño de píldora de estado', mark='check', time='7:55')
    done_hermes = row(hermes, 'Hermes', 'Terminó · Saludo amistoso', mark='check', time='7:12')

    def ahora_need(size, wide=True):
        height = size[1]
        ask = ('lw_ask', {'lw_ask_glyph': {'visible': False}, 'lw_ask_face': {'visible': True, 'src': hermes},
                          'lw_ask_title': {'text': 'Hermes pide permiso'}, 'lw_ask_detail': {'text': 'rm -rf build/'}})
        buttons = ('lw_buttons' if wide else 'lw_buttons_even', {'lw_button_open': {'visible': False}})
        room = body_height(height) - 42 - touch
        children = with_rows([ask, buttons], [run_forja, run_hermes, done_fable], room, lined=True)
        return board('lw_ic_bolt', 'Ahora', children, gold=True, card='lw_card_hero',
                     right='1 para ti · 2 en marcha' if wide else None)

    def ahora_run(size, wide=True):
        children = with_rows([], [run_hermes, run_forja, done_fable, done_hermes], body_height(size[1]), lined=False)
        return board('lw_ic_bolt', 'Ahora', children, gold=True, right='2 en marcha' if wide else None)

    def calm_line(mark_bg, icon, tint, title):
        return ('lw_calm', {'lw_calm_mark': {'bg': f'@drawable/{mark_bg}', 'src': f'@drawable/{icon}', 'tint': tint},
                            'lw_calm_title': {'text': title}})

    def ahora_calm(size):
        room = body_height(size[1]) - touch
        children = with_rows([calm_line('lw_okc_green', 'lw_ic_check', GREEN, 'Todo tranquilo')],
                             [done_fable, done_hermes], room, lined=True)
        return board('lw_ic_bolt', 'Ahora', children)

    def ahora_offline(size):
        room = body_height(size[1]) - touch
        old = row(hermes, 'Hermes', 'Terminó · Saludo amistoso', mark='check', time='5:40', dim=True)
        children = with_rows([calm_line('lw_okc_amber', 'lw_ic_cloud_off', AMBER, 'Sin conexión')], [old], room,
                             lined=True)
        return board('lw_ic_bolt', 'Ahora', children, right='6:05', right_color=AMBER, right_icon=True,
                     card='lw_card_stale')

    BUTTON_PROBES = [{'label': 'lw_button_yes_label', 'box': 'lw_button_yes_label'},
                     {'label': 'lw_button_no_label', 'box': 'lw_button_no_label'}]
    ahora_shots = [
        ('Ahora 2×1 · te necesita', cells['2x1'],
         strip(lead_face(astra), text('Astra', 'te pregunta', GOLD), card='lw_card_hero'), STRIP_PROBES),
        ('Ahora 2×1 · en marcha', cells['2x1'],
         strip(lead_face(hermes), text('Hermes', 'Terminal ·\u00a0'),
               {'lw_sub_timer': {'visible': True, 'text': '00:42'}}), STRIP_PROBES),
        ('Ahora 2×1 · tranquilo', cells['2x1'],
         strip(lead_glyph('lw_okc_green', 'lw_ic_check', GREEN), text('Todo tranquilo')), STRIP_PROBES),
        ('Ahora 2×1 · sin conexión', cells['2x1'],
         strip(lead_glyph('lw_okc_amber', 'lw_ic_cloud_off', AMBER), text('Sin conexión', 'desde las 6:05', AMBER),
               card='lw_card_stale'), STRIP_PROBES),
        ('Ahora 4×1 · te necesita', cells['4x1'], ask_strip(), ASK_PROBES),
        ('Ahora 4×1 · te necesita (Pixel)', pixel['4x1'], ask_strip(), ASK_PROBES),
        ('Ahora 4×1 · en marcha', cells['4x1'],
         strip(lead_face(hermes), text('Hermes · Terminal', 'Prueba con subagentes, herramientas y pensamiento'),
               {'lw_end_timer': {'visible': True, 'text': '00:42'}}), STRIP_PROBES),
        ('Ahora 4×1 · tranquilo', cells['4x1'],
         strip(lead_glyph('lw_okc_green', 'lw_ic_check', GREEN), text('Todo tranquilo', 'Fable terminó · 7:55')),
         STRIP_PROBES),
        ('Ahora 4×1 · bloqueado', cells['4x1'],
         strip(lead_glyph('lw_okc_gold', 'lw_ic_lock', GOLD), text('1 te necesita', '2 en marcha')), STRIP_PROBES),
        ('Ahora 4×2 · te necesita', cells['4x2'], ahora_need(cells['4x2']), BUTTON_PROBES + ROW_PROBES),
        ('Ahora 4×2 · en marcha', cells['4x2'], ahora_run(cells['4x2']), ROW_PROBES),
        ('Ahora 4×2 · tranquilo', cells['4x2'], ahora_calm(cells['4x2']), ROW_PROBES),
        ('Ahora 4×2 · sin conexión', cells['4x2'], ahora_offline(cells['4x2']), ROW_PROBES),
        ('Ahora 4×2 · te necesita (Pixel)', pixel['4x2'], ahora_need(pixel['4x2']), BUTTON_PROBES + ROW_PROBES),
        ('Ahora 4×3 · te necesita', cells['4x3'], ahora_need(cells['4x3']), BUTTON_PROBES + ROW_PROBES),
        ('Ahora 4×3 · en marcha', cells['4x3'], ahora_run(cells['4x3']), ROW_PROBES),
        ('Ahora 2×2 · te necesita', cells['2x2'], ahora_need(cells['2x2'], wide=False), BUTTON_PROBES),
        ('Ahora 2×2 · en marcha', cells['2x2'], ahora_run(cells['2x2'], wide=False), ROW_PROBES),
    ]
    # ------------------------------------------------------------ Cron
    def cron_row(time, day, name, sub, ok=True, failed=False):
        ov = {'lw_cron_time': {'text': time}, 'lw_cron_day': {'text': day}, 'lw_row_title': {'text': name},
              'lw_row_sub': {'text': sub}, 'lw_row_mark': {'visible': ok and not failed}}
        if failed:
            for key in ('lw_cron_time', 'lw_row_title', 'lw_row_sub'):
                ov[key]['color'] = RED
        return ('lw_row_cron', ov)

    cron_rows = [
        cron_row('17:00', 'hoy', 'Salida RRHH', 'Última: vie'),
        cron_row('21:00', 'hoy', 'Resumen del día', 'Última: ayer'),
        cron_row('3:00', 'mar', 'Copia de seguridad', 'Falló hoy a las 3:00', failed=True),
        cron_row('8:00', 'mar', 'Entrada RRHH', 'Última: hoy 8:00'),
        cron_row('9:00', 'vie', 'Informe semanal', 'Última: vie'),
    ]

    def cron_board(size, stale=False):
        children = with_rows([], cron_rows, body_height(size[1]), lined=False)
        if stale:
            return board('lw_ic_clock', 'Cron', children, right='8:00', right_color=AMBER, right_icon=True,
                         card='lw_card_stale')
        return board('lw_ic_clock', 'Cron', children, right='1 falló', right_color=RED)

    clock = lead_glyph('lw_icb', 'lw_ic_clock', MUTED)
    CRON_PROBES = board_probes('lw_cron_when')
    cron_shots = [
        ('Cron 2×1', cells['2x1'], strip(clock, text('Salida RRHH', 'hoy 17:00')), STRIP_PROBES),
        ('Cron 2×1 · con un fallo', cells['2x1'],
         strip(clock, text('Salida RRHH', 'hoy 17:00', sub2='1 falló', sub2_color=RED)), STRIP_PROBES),
        ('Cron 2×1 · sin noticias', cells['2x1'],
         strip(lead_glyph('lw_icb', 'lw_ic_cloud_off', AMBER),
               text('Salida RRHH', 'hoy 17:00', sub2='desde las 8:00', sub2_color=AMBER), card='lw_card_stale'),
         STRIP_PROBES),
        ('Cron 2×1 · sin datos', cells['2x1'],
         strip(clock, text('Cron', 'Sin datos aún')), STRIP_PROBES),
        ('Cron 4×1', cells['4x1'],
         strip(clock, text('Salida RRHH', 'hoy 17:00', sub2='1 falló', sub2_color=RED)), STRIP_PROBES),
        ('Cron 4×2', cells['4x2'], cron_board(cells['4x2']), CRON_PROBES),
        ('Cron 4×3', cells['4x3'], cron_board(cells['4x3']), CRON_PROBES),
        ('Cron 4×2 · sin noticias', cells['4x2'], cron_board(cells['4x2'], stale=True), CRON_PROBES),
        ('Cron 2×2', cells['2x2'], cron_board(cells['2x2']), CRON_PROBES),
    ]
    # ------------------------------------------------------------ Tareas
    def task_row(title, line, state):
        live = state != 'pending'
        ov = {'lw_row_face': {'visible': False},
              'lw_row_glyph': {'bg': None, 'src': '@drawable/lw_ic_spin' if state == 'running' else '@drawable/lw_ic_ring',
                               'tint': GOLD if live else MUTED},
              'lw_row_title': {'text': title}, 'lw_row_sub': {'text': line}}
        if live:
            ov['lw_row_sub']['color'] = GOLD
        return ('lw_row', ov)

    task_rows = [
        task_row('Publicar 1.2.15', 'Forja · en curso', 'running'),
        task_row('Rediseñar Inicio', 'Astra · en curso', 'running'),
        task_row('Probar GPT-Live con pantalla apagada', 'Pendiente', 'pending'),
        task_row('Notas de la versión 1.2.15', 'Pendiente', 'pending'),
        task_row('Revisar permisos de la sala Ideas', 'Pendiente', 'pending'),
    ]

    def tasks_board(size):
        wide = size[0] >= 250
        children = with_rows([], task_rows, body_height(size[1]), lined=False)
        return board('lw_ic_kanban', 'Tareas', children, right='2 en curso · 3 pendientes' if wide else None)

    kanban = lead_glyph('lw_icb', 'lw_ic_kanban', MUTED)
    tasks_shots = [
        ('Tareas 2×1 · en curso', cells['2x1'], strip(kanban, text('Publicar 1.2.15', 'Forja · en curso', GOLD)),
         STRIP_PROBES),
        ('Tareas 2×1 · pendiente', cells['2x1'], strip(kanban, text('Probar GPT-Live', 'Pendiente · +2')),
         STRIP_PROBES),
        ('Tareas 2×1 · sin noticias', cells['2x1'],
         strip(lead_glyph('lw_icb', 'lw_ic_cloud_off', AMBER),
               text('Publicar 1.2.15', 'Forja · en curso', sub2='desde las 8:00', sub2_color=AMBER),
               card='lw_card_stale'), STRIP_PROBES),
        ('Tareas 2×1 (Pixel)', pixel['2x1'], strip(kanban, text('Publicar 1.2.15', 'Forja · en curso', GOLD)),
         STRIP_PROBES),
        ('Tareas 4×1', cells['4x1'], strip(kanban, text('Publicar 1.2.15', 'Forja · en curso', GOLD)),
         STRIP_PROBES),
        ('Tareas 2×2', cells['2x2'], tasks_board(cells['2x2']), ROW_PROBES),
        ('Tareas 4×2', cells['4x2'], tasks_board(cells['4x2']), ROW_PROBES),
        ('Tareas 4×2 (Pixel)', pixel['4x2'], tasks_board(pixel['4x2']), ROW_PROBES),
        ('Tareas 4×3', cells['4x3'], tasks_board(cells['4x3']), ROW_PROBES),
    ]
    # ------------------------------------------------------------ Chats
    def chat_row(title, line, mark=None, timer=None, time=None, view=False):
        ov = {'lw_row_title': {'text': title}, 'lw_row_sub': {'text': line}}
        if mark == 'dot':
            ov['lw_row_mark'] = {'visible': True}
        elif mark == 'check':
            ov['lw_row_mark'] = {'visible': True, 'src': '@drawable/lw_ic_check', 'tint': GREEN}
        if timer:
            ov['lw_row_timer'] = {'visible': True, 'text': timer}
        if time:
            ov['lw_row_time'] = {'visible': True, 'text': time}
        if view:
            ov['lw_row_view'] = {'visible': True}
        return ('lw_row_chat', ov)

    def chat_rows(wide):
        return [
            chat_row('Diseño de píldora de estados', 'Pide permiso · rm -rf build/' if wide else 'Pide permiso',
                     mark='dot', view=True),
            chat_row('Prueba con subagentes, herramientas y pensamiento', 'Trabajando · Terminal', mark='dot',
                     timer='00:42'),
            chat_row('Saludo amistoso', 'Terminó · ¡Buenos días! ¿Qué hacemos hoy?', mark='check', time='7:12'),
            chat_row('Arreglar selección de modelo fallback', 'Terminó · Ya elige el de reserva si falla',
                     mark='check', time='ayer'),
            chat_row('Buscar cómo era onboarding nuevo', 'Terminó · Hola, necesito unos retoques', mark='check',
                     time='ayer'),
        ]

    def chats_board(size):
        children = with_rows([], chat_rows(size[0] >= 250), body_height(size[1]), lined=False)
        return board('lw_ic_history', 'Chats', children)

    history = lead_glyph('lw_icb', 'lw_ic_history', MUTED)
    # A conversation's row has no lead: its text starts at the card's padding.
    CHAT_PROBES = board_probes('lw_row_texts')
    chats_shots = [
        ('Chats 2×1 · trabajando', cells['2x1'],
         strip(history, text('Prueba con subagentes', 'Trabaja ·\u00a0', GOLD),
               {'lw_sub_timer': {'visible': True, 'text': '00:42'}}), STRIP_PROBES),
        ('Chats 2×1 · pide permiso', cells['2x1'],
         strip(history, text('Diseño de píldora de estados', 'Pide permiso', GOLD)), STRIP_PROBES),
        ('Chats 2×1 · el último', cells['2x1'], strip(history, text('Saludo amistoso', '7:12')), STRIP_PROBES),
        ('Chats 2×1 (Pixel)', pixel['2x1'],
         strip(history, text('Prueba con subagentes', 'Trabaja ·\u00a0', GOLD),
               {'lw_sub_timer': {'visible': True, 'text': '00:42'}}), STRIP_PROBES),
        ('Chats 4×1', cells['4x1'],
         strip(history, text('Prueba con subagentes, herramientas y pensamiento', 'Trabajando ·\u00a0', GOLD),
               {'lw_sub_timer': {'visible': True, 'text': '00:42'}}), STRIP_PROBES),
        ('Chats 2×2', cells['2x2'], chats_board(cells['2x2']), CHAT_PROBES),
        ('Chats 4×2', cells['4x2'], chats_board(cells['4x2']), CHAT_PROBES),
        ('Chats 4×2 (Pixel)', pixel['4x2'], chats_board(pixel['4x2']), CHAT_PROBES),
        ('Chats 4×3', cells['4x3'], chats_board(cells['4x3']), CHAT_PROBES),
    ]
    return [('chat_rapido', 'Chat rápido', quick_shots), ('ahora', 'Ahora', ahora_shots),
            ('cron', 'Cron', cron_shots), ('tareas', 'Tareas', tasks_shots), ('chats', 'Chats', chats_shots)]
