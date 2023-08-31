from peewee import *

from db.base import roverx_db, toad_db


class RoverXBaseModel(Model):
    class Meta:
        database = roverx_db
        legacy_table_names = False


class ToadBaseModel(Model):
    class Meta:
        database = toad_db
        legacy_table_names = False
