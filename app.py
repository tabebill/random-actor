from flask import Flask, render_template, jsonify
import random

app = Flask(__name__)

actors = [
    "Tom Hanks",
    "Meryl Streep",
    "Leonardo DiCaprio",
    "Jennifer Lawrence",
    "Brad Pitt",
    "Natalie Portman",
    "Denzel Washington",
    "Charlize Theron",
    "Robert Downey Jr.",
    "Cate Blanchett"
]

colors = [
    "red",
    "blue",
    "green",
    "orange",
    "purple",
    "yellow",
    "pink",
    "teal"
]

@app.route('/')
def generate_actor():
    actor = random.choice(actors)
    color = random.choice(colors)
    return render_template('index.html', actor=actor, color=color)

@app.route('/get_random_actor', methods=['GET'])
def get_random_actor():
    actor = random.choice(actors)
    color = random.choice(colors)
    return jsonify({'actor': actor, 'color': color})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5001)
