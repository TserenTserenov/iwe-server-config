"""CLI интерфейс для скилла /route."""

import json
import csv
import sys
from pathlib import Path
import click
from route import MaterialClassifier


@click.command()
@click.argument("material", type=str)
@click.option("--batch", type=click.Path(exists=True), default=None, help="Batch mode")
@click.option("--validate", is_flag=True, help="Validate mode")
@click.option("--model", type=click.Choice(["haiku", "sonnet", "opus"]), default="sonnet")
@click.option("--output", type=click.Choice(["text", "json", "csv"]), default="text")
@click.option("--confidence-threshold", type=float, default=0.8)
def route(material, batch, validate, model, output, confidence_threshold):
    """Маршрутизация материала пользователя по DP.KR.002."""
    # Phase B: LLM доступен для sonnet/opus, fallback при low confidence
    classifier = MaterialClassifier(llm_model=model if model != "haiku" else None)
    result = classifier.classify(material, use_llm_fallback=(model != "haiku"))
    
    if output == "json":
        click.echo(json.dumps(result.to_json(), indent=2, ensure_ascii=False))
    else:
        click.echo(f"Материал: {result.material_name}")
        if result.material_class:
            click.echo(f"Класс: {result.material_class.value}")
        click.echo(f"Дом: {result.home}")
        click.echo(f"Режим: {result.mode.value if result.mode else 'N/A'}")
        click.echo(f"Уверенность: {result.confidence:.2f}")


if __name__ == "__main__":
    route()
