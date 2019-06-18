from abc import ABC, abstractmethod
from os import path
from rapidscyber.io.factory.factory import Factory
import logging
import sys
import yaml

log = logging.getLogger("Workflow")


class Workflow(ABC):

    DEFAULT_CONFIG_FILE = "workflow.yaml"

    def __init__(self, source=None, destination=None, name="Workflow"):
        # Check to see if default workflow yaml file exists. If so, set workflow configurations from file.
        dirname, filename = path.split(
            path.abspath(sys.modules[self.__module__].__file__)
        )
        config_filepath = dirname + "/" + self.DEFAULT_CONFIG_FILE
        if path.exists(config_filepath):
            log.info("Config file detected: {0}".format(config_filepath))
            self._set_workflow_config(config_filepath)
        else:
            log.info("No config file detected: {0}".format(config_filepath))

        # If source or destination are passed in as parameters, update source and dest configurations.
        if source:
            self._source = source
            self._io_reader = Factory.get_reader(self._source["type"], self._source)
        if destination:
            self._destination = destination
            self._io_writer = Factory.get_writer(
                self._destination["type"], self._destination
            )
        if name:
            self._name = name

    def _set_workflow_config(self, yaml_file):
        # Receives a yaml file path with Workflow configurations and sets appropriate values for properties in this class
        log.info("Setting configurations from config file {0}".format(yaml_file))
        with open(yaml_file, "r") as ymlfile:
            config = yaml.load(ymlfile)
        if config["source"]:
            self._source = config["source"]
        if config["destination"]:
            self._destination = config["destination"]
        if config["name"]:
            self._name = config["name"]
        self._io_reader = Factory.get_reader(self._source["type"], self._source)
        self._io_writer = Factory.get_writer(
            self._destination["type"], self._destination
        )

    @property
    def name(self):
        """str: The name of the workflow for logging purposes."""
        return self._name

    @property
    def source(self):
        """dict: Configuration parameters for the data source"""
        return self._source

    def set_source(self, source):
        self._source = source
        self._io_reader = Factory.get_reader(self.source["type"], self.source)

    @property
    def destination(self):
        """dict: Configuration parameters for the data destination"""
        return self._destination

    def set_destination(self, destination):
        self._destination = destination
        self._io_writer = Factory.get_writer(
            self.source["destination"], self.destination
        )

    def _get_parser(self, parser_config):
        """TODO: Private helper function that fetches a specific parser based upon configuration"""
        pass

    def run_workflow(self):
        log.info("Running workflow {0}.".format(self.name))
        try:
            while (
                self._io_reader.has_data
            ):  # for a file this will be true only once. for streaming this will always return true
                dataframe = (
                    self._io_reader.fetch_data()
                )  # if kafka queue is empty just return None,
                if dataframe:
                    enriched_dataframe = self.workflow(dataframe)
                    self._io_writer.write_data(enriched_dataframe)
        except KeyboardInterrupt:
            self.stop_workflow()

    def stop_workflow(self):
        log.info("Workflow {0} stopped.".format(self.name))

    @abstractmethod
    def workflow(self, dataframe):
        """The pipeline function performs the data enrichment on the data.
        Subclasses must define this function. This function will return a gpu dataframe with enriched data."""
        pass
