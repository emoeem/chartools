import '../models/models.dart';

/// Fixed Jev question set, ported verbatim from the original
/// `tools/jev/questions.py` (the wording that passed calibration).
/// Instructions/criteria in English; chat text stays Chinese. The state `from`
/// field uses "me"/"other" (the instructions already refer to "the other
/// person" throughout).
abstract final class JevQuestions {
  /// Appended to every question so the D-stage `background` field
  /// (relationship, contact notes, knowledge-base hits) reads as given context
  /// rather than as an off-topic digression that should be penalized.
  static const backgroundNote =
      ' Facts given in background are provided context, not off-topic.';

  static Map<String, dynamic> _noul(String instructions, String t, String f) =>
      {
        'type': 'noul',
        'instructions': instructions + backgroundNote,
        'criteria': {'true': t, 'false': f},
      };

  static Map<String, dynamic> _choice(
    String instructions,
    Map<String, String> criteria,
  ) =>
      {
        'type': 'choice',
        'instructions': instructions + backgroundNote,
        'criteria': Map<String, String>.from(criteria),
      };

  static Map<String, dynamic> _score(
    String instructions,
    List<String> levels,
  ) =>
      {
        'type': 'score',
        'instructions': instructions + backgroundNote,
        'criteria': List<String>.from(levels),
      };

  /// The 7 judgment questions. Returns a fresh map each call.
  static Map<String, dynamic> judge() => {
        'literal_question': _noul(
          "Is the other person's latest message meant purely literally, with no "
              'subtext? Judge from the whole thread, not one sentence in isolation.',
          'The latest message is a straightforward statement, question, or plan '
              'with no implied accusation, test, sarcasm, hint, or unsaid request.',
          'There is subtext: a test of whether you remember or care, sarcasm, '
              'an implied complaint, a hint they will not say outright, a trap question, '
              'an accusation dressed as a question, or a cold/short line that really means blame.',
        ),
        'true_intent': _choice(
          "What is the other person's true intent in the latest message, given the "
              'full conversation? Prefer tone and context over surface wording. '
              'If they are checking whether you remember something or still care, choose '
              "confirm_you_care even if the words look like a request to 'say it' or to do "
              'something. '
              'If they already accepted and closed the matter peacefully, choose close_topic. '
              "Ending the relationship, deleting you, or 'don't talk to me' is vent_anger, "
              'never close_topic. '
              'If they are plainly continuing an intimate or role-play scene the two of you '
              'already set up, choose intimate_roleplay.',
          {
            'confirm_you_care':
                'They are testing whether you remember, pay attention, or still care. '
                    "Signals: 'did you forget again', 'then say it', 'you better', sarcastic "
                    "'busy person', asking you to prove you know a past conversation. "
                    'If they mainly want a new deliverable or a yes on a time, do not use this.',
            'vent_anger':
                'They are angry or hurt and mainly want the feeling acknowledged. '
                    'They are blaming or raising the temperature; a specific plan is not the '
                    'main point yet.',
            'request_action':
                'They want a concrete action, time, deliverable, or commitment from you now, '
                    'and this is a real ask, not a loyalty test.',
            'seek_explanation':
                'They want a factual explanation of why something happened. '
                    'They asked why or what is going on, not mainly for an apology or a new plan.',
            'casual_chat':
                'Light talk, banter, sharing, teasing with a laugh, or friendly logistics '
                    'with no emotional test and no conflict. A friend suggesting a meal time '
                    'can be this if the thread is warm.',
            'intimate_roleplay':
                'They are continuing a private, consensual intimate or role-play scene '
                    'the two of you already agreed on: an established pet name or dynamic, an '
                    'in-scene instruction, or an escalating description that expects you to '
                    'play along. Only choose this when the relationship note or the earlier '
                    'thread has already set the scene up. Never choose it for a stranger\'s '
                    'sexual message, and never when the thread mentions being underage, '
                    'unwilling, coerced, threatened, or drunk.',
            'close_topic':
                'Peaceful wrap-up only: they accepted an apology, confirmed a happy plan, '
                    'said thanks, or clearly signaled they need nothing more. '
                    "Not a breakup, not 'don't contact me', not sarcastic 'I'm used to it'.",
          },
        ),
        'danger_level': _score(
          'How close is this conversation to a fight or to hurting the relationship? '
              'Match the current scene. '
              'If they genuinely accepted an apology or confirmed a happy plan, score the '
              'cooled-down present, not an earlier complaint. '
              'If an ultimatum (break up, report to the boss, stop covering for you) is still '
              'in force and has not been withdrawn, stay in that high bin even if the latest '
              'line names a specific task.',
          [
            'Light chat or joking; no complaint, no test, no deadline.',
            'Mild tease or a small reminder that is easy to laugh off; a clumsy reply would '
                'only feel slightly awkward.',
            "A mild complaint or 'please remember next time' said without heat; they still "
                'send warm or practical follow-ups.',
            'Noticeable unhappiness; they mention being forgotten, ignored, or kept waiting, '
                'but still give you a chance to make it right.',
            "Sarcasm, cold short replies, or 'you better'; they are testing you, and a sloppy "
                'or fake-confident reply will escalate.',
            'Openly upset; they accuse you of not listening or not caring; they expect a real '
                'response, not a joke.',
            'Clearly angry and blaming you; a wrong reply will turn this into a fight.',
            'Last-chance warning. They will not cover for you, do not want to keep talking '
                'unless this changes, or tell you to finish a named checklist yourself because '
                'trust is almost gone.',
            'An ultimatum is already on the table even if they also give a practical next '
                'step: break up if you forget again, report you tonight, or stop working '
                'together if you miss this.',
            'Active rupture: they said it is over, told you not to reply, deleted you, or '
                'are exploding.',
          ],
        ),
        'should_reply_now': _noul(
          'Should your next message contain substantive content? '
              'Substantive means: admitting a specific known fault, giving a concrete '
              'time/plan/deliverable, explaining facts you actually know, or reciting the '
              'recalled content they asked you to say. '
              "This is NOT 'should you send any message'. Timing is irrelevant. "
              'Answer FALSE if the thing they want you to recite or prove is not present in '
              "this snippet (you would be guessing). 'Then say it' / 'you better' while you "
              'are stalling is FALSE. '
              'Answer FALSE if they already accepted and closed the topic. '
              'Answer true only if the needed fact, plan, or named fault is already in this '
              'snippet.',
          'The needed fact, named fault, or named time/place is already in this snippet, '
              'and they are waiting for that substance now.',
          'Do not put substance in the next message: the recalled content is not in this '
              'snippet, they are testing whether you remember, a holding line is enough, '
              'saying less is safer, or they already closed the topic.',
        ),
        'best_action': _choice(
          'What type of next action is best? Do not decide whether to send a message '
              'immediately. Ignore timing. Choose only the action type. '
              'If they asked you to recall a specific past message or event and you have not '
              'shown that you actually remember it, choose check_history - do not apologize '
              'or invent a plan instead. '
              'For an intimate or role-play scene that is already set up and clearly '
              'consensual, choose play_along rather than explain, acknowledge, or make_plan.',
          {
            'check_history':
                'Look up prior chat or facts before taking a position. '
                    'Use when they ask you to repeat, recall, or prove you remember something '
                    'specific.',
            'apologize':
                'Lead with a sincere apology for a real mistake or hurt already identified. '
                    'Not for an unnamed forgotten thing when you should first find out what it was.',
            'give_commitment':
                'Give a concrete promise, deadline, or arrangement they asked for '
                    'in a conflict or work-pressure setting.',
            'explain':
                'Explain what happened or why, without leading with apology or a new plan.',
            'acknowledge':
                'Show you heard them and care, without new facts, an apology, or a plan. '
                    'Use for light chat or when they mainly need to feel seen.',
            'say_less':
                'Keep it short or add nothing. Extra words would over-explain, reopen a '
                    'closed topic, or pour fuel on an ultimatum that told you not to talk.',
            'make_plan':
                'Propose or confirm logistics (time, place, task) for a non-conflict request '
                    'such as a meal or a meeting.',
            'play_along':
                'Continue the scene they just moved forward: answer in the voice and dynamic '
                    'already established, stay inside the agreed boundaries, and do not steer '
                    'back to small talk, advice, or an apology. Use only for an intimate or '
                    'role-play thread that is already set up and clearly consensual.',
          },
        ),
        'she_needs': _choice(
          'What does the other person need from you right now? Judge the LATEST message '
              'first. If they genuinely accepted (thanks / got it / 没事了 / 那就这样 / 收到了 / '
              '过去了), you MUST choose nothing, even if earlier they wanted action or an '
              "apology. Sarcastic 'I'm used to it', 'whatever', 'I don't want to hear it', "
              "'don't bother coming' is NOT genuine satisfaction - do not choose nothing. "
              'If they asked you to recap a named time/place/date, choose action. '
              'If they are testing whether you remember or still care, and the content is '
              'unnamed, choose care.',
          {
            'apology':
                'They need a sincere apology for hurt or a mistake, and they have not '
                    'accepted one yet.',
            'action':
                'They need a concrete action, time, commitment, recap of a named fact, or '
                    'follow-through, and they have not yet accepted one.',
            'explanation':
                'They need a clear explanation of what happened or why, and have not '
                    'received it.',
            'care':
                'They need proof you remember, listen, or care - a loyalty or attention test '
                    "- not yet a plan or an apology. Sarcastic 'I am used to it' belongs here, "
                    'not nothing.',
            'nothing':
                'They need nothing further. Genuine acceptance, a peaceful closed topic, '
                    'warm casual chat with no ask, or a rupture where they told you not to '
                    'reply. Not sarcasm pretending to be fine.',
            'engagement':
                'They need you to be present inside the scene or the playful exchange that is '
                    'already running - to answer in kind, keep the dynamic, and give them '
                    'something to play off. Not an apology, not an explanation, not a plan, '
                    'not a summary of what they said. Only for an intimate or role-play thread '
                    'that is clearly consensual and already set up.',
          },
        ),
        'tension_resolved': _noul(
          'Has interpersonal tension already been resolved? '
              'Answer true only if there was never tension, or the other person has clearly '
              'accepted, cooled down, joked again, or said it is fine. '
              "A sarcastic 'you better', an unanswered test, leftover blame, or an open "
              'ultimatum means false.',
          "No remaining tension: they accepted, joked again, said it's fine, "
              'confirmed a happy plan, or the chat was never tense.',
          'Tension is still present: they are waiting, testing, angry, sarcastic, '
              'issuing an ultimatum, or the issue is open.',
        ),
      };

  /// Build Jev state from a snapshot (last 10 messages), optionally carrying
  /// the D-stage knowledge context.
  ///
  /// [background]: relationship + contact notes + matched knowledge notes.
  /// [history]: older messages for this contact, already de-duplicated against
  /// what is on screen.
  ///
  /// Both extra fields are omitted when empty, so a user with no knowledge base
  /// sends exactly the same body the original app did.
  static Map<String, dynamic> buildState(
    ChatSnapshot snapshot,
    String relationship, {
    String background = '',
    List<({String side, String text})> history = const [],
  }) {
    final last10 = snapshot.messages.length <= 10
        ? snapshot.messages
        : snapshot.messages.sublist(snapshot.messages.length - 10);
    final msgs = [
      for (final m in last10) {'from': m.side, 'text': m.text},
    ];
    final chat = <String, dynamic>{
      'relationship': relationship,
      'messages': msgs,
      'latest_from': last10.isEmpty ? 'other' : last10.last.side,
    };
    // How the sides were read. When a snapshot came from a flat-screen OCR
    // read, some or all of these "other" labels may be guesses; the judge has
    // to know that, or it answers a question about who said what that the
    // capture step could not actually answer.
    final unknownCount = last10.where((m) => !m.sideKnown).length;
    if (unknownCount > 0) chat['sides_unclear'] = unknownCount;
    final note = snapshot.note;
    if (note != null && note.trim().isNotEmpty) chat['note'] = note;
    final state = <String, dynamic>{'chat': chat};
    if (background.trim().isNotEmpty) state['background'] = background;
    if (history.isNotEmpty) {
      state['history'] = [
        for (final h in history) {'from': h.side, 'text': h.text},
      ];
    }
    return state;
  }

  /// The best_reply ranking question over exactly 3 candidates (Chinese kept).
  static Map<String, dynamic> rankQuestion(List<String> candidates) {
    if (candidates.length != 3) {
      throw ArgumentError.value(candidates, 'candidates',
          'rankQuestion expects exactly 3 candidates');
    }
    const keys = ['reply_a', 'reply_b', 'reply_c'];
    final criteria = <String, String>{
      for (var i = 0; i < 3; i++) keys[i]: candidates[i],
    };
    final q = {
      'type': 'choice',
      'instructions': 'Which candidate reply is the most appropriate next message, '
              'given the conversation and the other person\'s true need? '
              'Prefer a reply that matches the best action type. '
              'Penalize dismissive, over-promising, or off-topic replies. '
              'If the facts are not yet confirmed, prefer the candidate that looks them up '
              'instead of faking memory or a vague apology.$backgroundNote',
      'criteria': criteria,
    };
    return {'best_reply': q};
  }
}
