// Sample module: the learner selects the steps in order. The score is the percent of steps in the correct place.
const correct = ["Write the objective", "Plan the sections", "Write the lectures", "Publish the course"];
const shuffled = [correct[2], correct[0], correct[3], correct[1]];
let picked = [];

function render() {
  const list = document.getElementById("steps");
  list.replaceChildren();
  for (const step of shuffled) {
    const item = document.createElement("li");
    const button = document.createElement("button");
    button.textContent = step;
    button.disabled = picked.includes(step);
    button.addEventListener("click", () => pick(step));
    item.append(button);
    list.append(item);
  }
  document.getElementById("status").textContent = picked.length ? "Your order: " + picked.join(", ") : "";
}

function pick(step) {
  picked.push(step);
  if (picked.length === correct.length) {
    const right = picked.filter((value, index) => value === correct[index]).length;
    Skillgarden.submitScore(Math.round(right * 100 / correct.length));
    Skillgarden.complete();
  }
  render();
}

document.getElementById("reset").addEventListener("click", () => { picked = []; render(); });
render();
