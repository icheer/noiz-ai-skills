---
name: daily-news-caster
description: Fetches the latest news using news-aggregator-skill, formats it into a podcast script in Markdown format, and uses the tts skill to generate a podcast audio file. Use when the user asks to get the latest news and read it out as a podcast.
---

# Daily News Caster Skill

This skill allows the agent to fetch real-time news, organize it into a conversational podcast script, and generate an audio file reading the script out loud.

## Workflow Instructions

When the user asks to get the latest news and make a podcast out of it, follow these steps strictly:

### Step 1: Ensure Skills are Installed
If the `news-aggregator-skill` and `tts` skills are not already installed in the workspace, run the following commands to install them:
```bash
npx skills add https://github.com/cclank/news-aggregator-skill --skill news-aggregator-skill -y
npx skills add https://github.com/noizai/skills --skill tts -y
```

### Step 2: Fetch the Latest News
Find the `fetch_news.py` script from the `news-aggregator-skill` (usually located in `.cursor/skills/news-aggregator-skill/scripts/fetch_news.py` or `skills/news-aggregator-skill/scripts/fetch_news.py`).

Run the script to fetch real-time news. You can specify a source (e.g., `hackernews`, `github`, `all`) or keywords based on the user's request.
Example command:
```bash
python3 path/to/fetch_news.py --source all --limit 10 --deep
```

### Step 3: Write the Podcast Script
Read the fetched news data and rewrite the information into a **Markdown podcast script**. 
**Crucially, prioritize a dual-host (two-person) conversational format** (e.g., Host A and Host B) in a dynamic **Q&A style**.
The script should be:
- **Dual-Host Conversational yet concise:** Write an engaging back-and-forth between two hosts. **Host A should ask insightful, high-value questions** to guide the conversation, and **Host B should provide informative, concise answers**. It should feel like a smart, fast-paced Q&A dialogue.
- **Avoid fluff:** Do not include unnecessary fluff or overly long transitions. Keep it to the point (言简意赅) while retaining all critical information and facts.
- **Clearly Labeled Speakers:** Start each line or paragraph with the speaker's name (e.g., `Host A:` or `Host B:`).
- **Structured:** Use markdown headings and clear paragraphs.
- **Clear text for speech:** Avoid complex URLs, raw markdown links, or unpronounceable characters in the spoken text.

Save this script to a local file named `podcast_script.md`.

**Example `podcast_script.md` Content:**
```markdown
**Host A:** Welcome to today's news roundup. We have some exciting tech updates today. To start things off, there's a big update from [Company Name]. What are the core implications of their new release for everyday users?

**Host B:** The main takeaway is that... [Insert concise answer and summary of News Item 1]. This completely changes how we approach [Topic].

**Host A:** That's fascinating. But does this new approach raise any security concerns, especially given recent data breaches?

**Host B:** Exactly. Experts are pointing out that... [Insert analysis or context]. 

**Host A:** Moving on to the open-source world, what's trending on GitHub today that developers should pay attention to?

**Host B:** A standout project is... [Insert concise summary of News Item 2].

**Host A:** Great insights. That's all for today's quick update. Thanks for tuning in!
```

### Step 4: Generate the Podcast Audio
Use the `tts` skill to convert the script into an audio file. Since it's a dual-host format, you must use the **Timeline Mode** of the `tts` skill.

Find the `tts.sh` script (usually located in `skills/tts/scripts/tts.sh` or `.cursor/skills/tts/scripts/tts.sh`).

**1. Generate SRT**: Convert the script to SRT format.
```bash
bash path/to/tts.sh to-srt -i podcast_script.md -o podcast.srt
```

**2. Create a Voice Map (`voice_map.json`)**:
Map the lines in the SRT to the corresponding host. **If the user provided reference audio files or URLs for the two roles**, you **MUST** use them via the `reference_audio` field (requires `noiz` backend). Otherwise, assign default distinct voices.
```json
{
  "default": { "voice_id": "voice_host_A", "target_lang": "zh" },
  "segments": {
    "1": { "reference_audio": "path/or/url_to_user_audio_for_host_A.wav" },
    "2": { "reference_audio": "path/or/url_to_user_audio_for_host_B.wav" },
    "3": { "reference_audio": "path/or/url_to_user_audio_for_host_A.wav" }
  }
}
```
*(Adjust the segment numbers corresponding to the generated SRT lines for Host A and Host B).*

**3. Render Audio**:
```bash
# If using user's reference_audio, use the noiz backend
bash path/to/tts.sh render --srt podcast.srt --voice-map voice_map.json --backend noiz -o podcast_output.mp3
```

### Step 5: Present the Result
Let the user know that the podcast has been successfully generated. You **MUST** provide both files back to the user:
- Show or link to the `podcast_script.md` file so they can read the script.
- Provide the path to the `podcast_output.mp3` file so they can listen to the audio.
- Briefly summarize the headlines that were included in the podcast.
